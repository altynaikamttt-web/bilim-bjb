-- Run once in Supabase SQL Editor. Safe to rerun; existing work is preserved.
begin;
create schema if not exists bilim_private;
revoke all on schema bilim_private from public, anon, authenticated;
create table if not exists bilim_private.teachers(user_id uuid primary key references auth.users(id) on delete cascade);
create table if not exists bilim_private.exams(id uuid primary key default gen_random_uuid(), data jsonb not null, active boolean not null default true, created timestamptz not null default now());
create table if not exists bilim_private.attempts(id uuid primary key default gen_random_uuid(), exam_id uuid not null references bilim_private.exams(id), name text not null, class_name text not null, snapshot jsonb not null, started timestamptz not null default now(), submitted timestamptz, result jsonb);
alter table bilim_private.teachers enable row level security;
alter table bilim_private.exams enable row level security;
alter table bilim_private.attempts enable row level security;
revoke all on all tables in schema bilim_private from public, anon, authenticated;
create index if not exists bilim_attempt_submitted on bilim_private.attempts(submitted desc);

create or replace function bilim_private.validate_exam(x jsonb) returns jsonb language plpgsql set search_path='' as $$
declare q jsonb; cleaned jsonb := '[]'; item jsonb; opt jsonb; a jsonb;
begin
 if jsonb_typeof(x) is distinct from 'object' then raise exception 'БЖБ нысаны дұрыс емес'; end if;
 if jsonb_typeof(x->'grade') is distinct from 'number' or (x->>'grade') !~ '^[5-9]$' then raise exception 'Сынып 5–9 аралығында'; end if;
 if jsonb_typeof(x->'title') is distinct from 'string' or length(btrim(x->>'title')) not between 1 and 200 or jsonb_typeof(x->'section') is distinct from 'string' or length(btrim(x->>'section')) not between 1 and 200 then raise exception 'Атауы мен бөлімін толтырыңыз'; end if;
 if x->>'kind' is null or x->>'kind' not in ('БЖБ','ТЖБ') then raise exception 'Бағалау түрі дұрыс емес'; end if;
 if jsonb_typeof(x->'minutes') is distinct from 'number' or (x->>'minutes') !~ '^[0-9]{1,3}$' then raise exception 'Уақыт бүтін сан болсын'; end if;
 if (x->>'minutes')::int not between 1 and 180 then raise exception 'Уақыт 1–180 минут'; end if;
 if jsonb_typeof(x->'questions') is distinct from 'array' then raise exception 'Тапсырмалар тізімі қажет'; end if;
 if jsonb_array_length(x->'questions') not between 1 and 60 then raise exception '1–60 тапсырма қажет'; end if;
 for q in select value from jsonb_array_elements(x->'questions') loop
  if jsonb_typeof(q->'text') is distinct from 'string' or length(btrim(q->>'text')) not between 1 and 5000 then raise exception 'Сұрақ мәтіні қажет'; end if;
  if jsonb_typeof(q->'points') is distinct from 'number' or (q->>'points') !~ '^[0-9]{1,2}$' then raise exception 'Балл бүтін сан болсын'; end if;
  if (q->>'points')::int not between 1 and 20 then raise exception 'Балл 1–20 аралығында'; end if;
  item:=jsonb_build_object('type',q->>'type','text',q->>'text','points',(q->>'points')::int);
  if q->>'type'='choice' then
   if jsonb_typeof(q->'options') is distinct from 'array' then raise exception 'Нұсқалар тізімі қажет'; end if;
   if jsonb_array_length(q->'options') not between 2 and 8 then raise exception '2–8 нұсқа қажет'; end if;
   for opt in select value from jsonb_array_elements(q->'options') loop
    if jsonb_typeof(opt) is distinct from 'string' or length(btrim(opt#>>'{}')) not between 1 and 1000 then raise exception 'Жауап нұсқасы бос'; end if;
   end loop;
   if jsonb_typeof(q->'answer') is distinct from 'number' or (q->>'answer') !~ '^[0-7]$' then raise exception 'Дұрыс жауап индексі қажет'; end if;
   if (q->>'answer')::int>=jsonb_array_length(q->'options') then raise exception 'Дұрыс жауап индексі қате'; end if;
   item:=item||jsonb_build_object('options',q->'options','answer',(q->>'answer')::int);
  elsif q->>'type'='short' then
   if jsonb_typeof(q->'answers') is distinct from 'array' then raise exception 'Қысқа жауап кілттері қажет'; end if;
   if jsonb_array_length(q->'answers') not between 1 and 30 then raise exception '1–30 балама жауап қажет'; end if;
   for a in select value from jsonb_array_elements(q->'answers') loop
    if jsonb_typeof(a) is distinct from 'string' or length(btrim(a#>>'{}')) not between 1 and 1000 then raise exception 'Жауап кілті бос'; end if;
   end loop;
   item:=item||jsonb_build_object('answers',q->'answers');
  else raise exception 'Тапсырма түрі дұрыс емес'; end if;
  cleaned:=cleaned||jsonb_build_array(item);
 end loop;
 return jsonb_build_object('grade',(x->>'grade')::int,'title',btrim(x->>'title'),'section',btrim(x->>'section'),'kind',x->>'kind','minutes',(x->>'minutes')::int,'questions',cleaned,'sample',x->'sample'='true'::jsonb);
end $$;
revoke all on function bilim_private.validate_exam(jsonb) from public,anon,authenticated;

-- Capability-scoped public API: students receive no answer keys or result lists.
create or replace function public.bilim_api(action text, payload jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
 teacher boolean; output jsonb; ex bilim_private.exams%rowtype; atp bilim_private.attempts%rowtype;
 exam jsonb; safe_questions jsonb; q jsonb; ans jsonb; details jsonb:='[]'; idx int:=0;
 points int; score int:=0; total int:=0; pct numeric; late boolean; correct boolean;
 current_time_ timestamptz:=clock_timestamp(); name_ text; class_ text; normalized text;
begin
 select exists(select 1 from bilim_private.teachers where user_id=auth.uid()) into teacher;
 if octet_length(payload::text)>2000000 then raise exception 'Файл 2 МБ-тан аспасын'; end if;
 if action='status' then return jsonb_build_object('configured',true); end if;
 if action='whoami' then
  if not teacher then raise exception 'Бұл аккаунтқа мұғалім құқығы берілмеген'; end if;
  return jsonb_build_object('teacher',true);
 end if;
 if action='exams' then
  select coalesce(jsonb_agg((case when teacher then e.data else e.data-'questions' end)||jsonb_build_object('id',e.id,'active',e.active) order by e.created desc),'[]'::jsonb) into output from bilim_private.exams e where teacher or e.active;
  return output;
 end if;
 if action in ('save_exam','toggle','results') then
  if not teacher then raise exception 'Мұғалім ретінде кіріңіз'; end if;
  if action='save_exam' then
   exam:=bilim_private.validate_exam(payload); insert into bilim_private.exams(data) values(exam) returning id into ex.id;
   return jsonb_build_object('id',ex.id);
  elsif action='toggle' then
   update bilim_private.exams set active=not active where id=(payload->>'id')::uuid;
   return jsonb_build_object('ok',true);
  else
   select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'name',a.name,'class_name',a.class_name,'started',extract(epoch from a.started),'submitted',extract(epoch from a.submitted),'exam',a.snapshot,'result',a.result) order by a.submitted desc),'[]'::jsonb) into output from bilim_private.attempts a where a.submitted is not null;
   return output;
  end if;
 end if;
 if action='start' then
  name_:=btrim(payload->>'name'); class_:=btrim(payload->>'class_name');
  if name_ is null or length(name_) not between 2 and 100 or class_ is null or length(class_) not between 1 and 20 then raise exception 'Аты-жөніңіз бен сыныбыңызды енгізіңіз'; end if;
  select * into ex from bilim_private.exams where id=(payload->>'exam_id')::uuid and active;
  if not found then raise exception 'Бұл жұмыс жабық немесе табылмады'; end if;
  insert into bilim_private.attempts(exam_id,name,class_name,snapshot,started) values(ex.id,name_,class_,ex.data,current_time_) returning * into atp;
  select jsonb_agg(value-'answer'-'answers' order by ordinality) into safe_questions from jsonb_array_elements(ex.data->'questions') with ordinality;
  return jsonb_build_object('id',atp.id,'title',ex.data->>'title','questions',safe_questions,'server_now',extract(epoch from current_time_),'deadline',extract(epoch from current_time_)+(ex.data->>'minutes')::int*60);
 end if;
 if action='submit' then
  select * into atp from bilim_private.attempts where id=(payload->>'id')::uuid for update;
  if not found then raise exception 'Жұмыс табылмады'; end if;
  if atp.submitted is not null then return atp.result; end if;
  if jsonb_typeof(payload->'answers') is distinct from 'array' then raise exception 'Жауаптар тізімі қажет'; end if;
  exam:=atp.snapshot;
  if jsonb_array_length(payload->'answers')<>jsonb_array_length(exam->'questions') then raise exception 'Жауаптар саны сәйкес емес'; end if;
  late:=current_time_>atp.started+make_interval(secs=>(exam->>'minutes')::int*60+15);
  for q in select value from jsonb_array_elements(exam->'questions') loop
   ans:=payload->'answers'->idx; correct:=false;
   if jsonb_typeof(ans) not in ('string','number','null') then raise exception 'Жауап пішімі дұрыс емес'; end if;
   if length(ans::text)>5010 then raise exception 'Жауап тым ұзын'; end if;
   if q->>'type'='choice' then
    correct:=jsonb_typeof(ans)='number' and ans=q->'answer';
   elsif jsonb_typeof(ans)='string' then
    normalized:=lower(btrim(regexp_replace(ans#>>'{}','\s+',' ','g')));
    select exists(select 1 from jsonb_array_elements_text(q->'answers') a where lower(btrim(regexp_replace(a,'\s+',' ','g')))=normalized) into correct;
   end if;
   points:=case when correct and not late then (q->>'points')::int else 0 end;
   score:=score+points; total:=total+(q->>'points')::int;
   details:=details||jsonb_build_array(jsonb_build_object('answer',ans,'points',points)); idx:=idx+1;
  end loop;
  pct:=round(score::numeric/total*100,1);
  output:=jsonb_build_object('score',score,'total',total,'percent',pct,'details',details,'late',late,'duration',round(extract(epoch from current_time_-atp.started)));
  update bilim_private.attempts set submitted=current_time_,result=output where id=atp.id;
  return output;
 end if;
 raise exception 'Белгісіз әрекет';
end $$;
revoke all on function public.bilim_api(text,jsonb) from public,anon,authenticated;
grant execute on function public.bilim_api(text,jsonb) to anon,authenticated;

-- Public demonstration material only, not confidential assessments.
insert into bilim_private.exams(data) select bilim_private.validate_exam('{"grade": 5, "title": "Компьютер және қауіпсіздік", "section": "Ақпараттық қауіпсіздік", "kind": "БЖБ", "minutes": 20, "questions": [{"type": "choice", "text": "Бейтаныс адам құпиясөзіңді сұрады. Қай әрекет дұрыс?", "options": ["Құпиясөзді жіберемін", "Досымнан сұрап, жіберемін", "Құпиясөзді бермеймін, ересекке хабарлаймын", "Әлеуметтік желіге жазамын"], "answer": 2, "points": 2}, {"type": "choice", "text": "Ақпаратты енгізу құрылғысын таңда.", "options": ["Монитор", "Пернетақта", "Принтер", "Динамик"], "answer": 1, "points": 2}, {"type": "choice", "text": "Файл атауындағы .png кеңейтімі әдетте нені білдіреді?", "options": ["Дыбыс файлы", "Кескін файлы", "Бағдарлама коды", "Мәтіндік құжат"], "answer": 1, "points": 2}, {"type": "short", "text": "8 бит неше байт болады? Тек санды жаз.", "answers": ["1"], "points": 2}, {"type": "choice", "text": "Компьютерде жұмыс істегенде дұрыс әрекетті таңда.", "options": ["Сымдарды дымқыл қолмен ұстау", "Экранға өте жақын отыру", "Үзіліс жасап, дұрыс отыру", "Тамақты пернетақта үстіне қою"], "answer": 2, "points": 2}], "sample": true}'::jsonb) where not exists(select 1 from bilim_private.exams where data->>'title'='Компьютер және қауіпсіздік' and data->>'grade'='5');
insert into bilim_private.exams(data) select bilim_private.validate_exam('{"grade": 6, "title": "Компьютерлік жүйелер және алгоритмдер", "section": "Алгоритмдеу негіздері", "kind": "БЖБ", "minutes": 20, "questions": [{"type": "choice", "text": "Алгоритм дегеніміз не?", "options": ["Кез келген сурет", "Мақсатқа жетуге арналған нақты әрекеттер тізбегі", "Тек компьютер құрылғысы", "Файл түрі"], "answer": 1, "points": 2}, {"type": "choice", "text": "Бірнеше рет орындалатын әрекеттерді ұйымдастыратын құрылым:", "options": ["Тармақталу", "Сызықтық құрылым", "Цикл", "Айнымалы атауы"], "answer": 2, "points": 2}, {"type": "choice", "text": "Егер шарт ақиқат болса, бір әрекет, әйтпесе басқа әрекет орындалады. Бұл қандай құрылым?", "options": ["Цикл", "Тармақталу", "Енгізу", "Сақтау"], "answer": 1, "points": 2}, {"type": "short", "text": "x = 4; содан кейін x = x + 3 орындалды. x мәні қандай?", "answers": ["7"], "points": 2}, {"type": "choice", "text": "Айнымалы не үшін қолданылады?", "options": ["Деректі сақтау үшін", "Мониторды қосу үшін", "Файлды басып шығару үшін", "Экранды тазалау үшін"], "answer": 0, "points": 2}], "sample": true}'::jsonb) where not exists(select 1 from bilim_private.exams where data->>'title'='Компьютерлік жүйелер және алгоритмдер' and data->>'grade'='6');
insert into bilim_private.exams(data) select bilim_private.validate_exam('{"grade": 7, "title": "Ақпаратты өлшеу және Python", "section": "Деректерді өңдеу", "kind": "БЖБ", "minutes": 20, "questions": [{"type": "short", "text": "Осы тапсырмада 1 Кбайт = 1024 байт. 2 Кбайт неше байт?", "answers": ["2048"], "points": 2}, {"type": "choice", "text": "Python тілінде бүтін санның типін таңда.", "options": ["str", "int", "float", "bool"], "answer": 1, "points": 2}, {"type": "short", "text": "Python: print(3 * 4 + 2). Экранға қандай сан шығады?", "answers": ["14"], "points": 2}, {"type": "choice", "text": "input() функциясы бастапқыда қандай типтегі дерек қайтарады?", "options": ["int", "float", "str", "bool"], "answer": 2, "points": 2}, {"type": "short", "text": "Python: x = 5\nx = x + 2\nprint(x)\nНәтижесін жаз.", "answers": ["7"], "points": 2}], "sample": true}'::jsonb) where not exists(select 1 from bilim_private.exams where data->>'title'='Ақпаратты өлшеу және Python' and data->>'grade'='7');
insert into bilim_private.exams(data) select bilim_private.validate_exam('{"grade": 8, "title": "Электрондық кестелер", "section": "Деректерді талдау", "kind": "БЖБ", "minutes": 20, "questions": [{"type": "choice", "text": "Кестеде формула қандай таңбадан басталады?", "options": ["#", "=", ":", "@"], "answer": 1, "points": 2}, {"type": "short", "text": "A1 ұяшығында 8, B1 ұяшығында 3 жазылған. =A1+B1 формуласының нәтижесі қандай?", "answers": ["11"], "points": 2}, {"type": "choice", "text": "A1:A5 жазбасы нені білдіреді?", "options": ["Бір ұяшық", "A1-ден A5-ке дейінгі ұяшықтар ауқымы", "Бес парақ", "Тек A1 және A5"], "answer": 1, "points": 2}, {"type": "choice", "text": "Абсолютті сілтемені таңда.", "options": ["A1", "$A$1", "A$1", "$A1"], "answer": 1, "points": 2}, {"type": "short", "text": "A1 = 4, A2 = 6, A3 = 8. =SUM(A1:A3) нәтижесін жаз.", "answers": ["18"], "points": 2}], "sample": true}'::jsonb) where not exists(select 1 from bilim_private.exams where data->>'title'='Электрондық кестелер' and data->>'grade'='8');
insert into bilim_private.exams(data) select bilim_private.validate_exam('{"grade": 9, "title": "Логика және программалау", "section": "Логикалық негіздер", "kind": "БЖБ", "minutes": 20, "questions": [{"type": "choice", "text": "A = 1, B = 0 болса, A AND B мәні қандай?", "options": ["0", "1", "2", "Анықталмайды"], "answer": 0, "points": 2}, {"type": "choice", "text": "A = 0, B = 1 болса, A OR B мәні қандай?", "options": ["0", "1", "2", "Анықталмайды"], "answer": 1, "points": 2}, {"type": "short", "text": "NOT 1 өрнегінің мәнін 0 немесе 1 түрінде жаз.", "answers": ["0"], "points": 2}, {"type": "short", "text": "Үш логикалық айнымалысы бар толық ақиқат кестесінде неше дерек жолы болады? Тақырып жолын есептеме.", "answers": ["8"], "points": 2}, {"type": "short", "text": "Python: s = 0\nfor i in range(1, 4):\n    s += i\nprint(s)\nНәтижені жаз.", "answers": ["6"], "points": 2}], "sample": true}'::jsonb) where not exists(select 1 from bilim_private.exams where data->>'title'='Логика және программалау' and data->>'grade'='9');
commit;
notify pgrst, 'reload schema';

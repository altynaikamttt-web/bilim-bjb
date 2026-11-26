-- 1. Authentication > Users > Add user: create and confirm the teacher.
-- 2. Replace teacher@example.com below with that exact account email.
-- 3. Run this file in Supabase SQL Editor. Never put the password here.
do $$
declare teacher_email text := 'teacher@example.com'; teacher_id uuid;
begin
 select id into teacher_id from auth.users where lower(email)=lower(teacher_email);
 if teacher_id is null then raise exception 'Алдымен Authentication > Users ішінде осы email-мен аккаунт жасаңыз: %',teacher_email; end if;
 insert into bilim_private.teachers(user_id) values(teacher_id) on conflict do nothing;
end $$;

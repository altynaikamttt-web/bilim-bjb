(() => {
  'use strict';
  const button = document.getElementById('installApp');
  if (!button) return;
  let pending = null;
  let installed = false;
  const mode = window.matchMedia('(display-mode: standalone)');
  function paint() { button.hidden = installed || mode.matches || !!navigator.standalone; }
  function help(message) {
    const el = document.getElementById('pwaHelp') || document.createElement('dialog');
    el.id = 'pwaHelp';
    el.innerHTML = '<h2>Установка Bilim на компьютер</h2>' +
      '<p>Откройте сайт в обычном окне Microsoft Edge или Google Chrome.</p>' +
      '<p>Нажмите значок установки справа в адресной строке браузера и подтвердите установку. Если значка нет, откройте меню браузера и найдите пункт установки приложения.</p>' +
      '<p>В Яндекс Браузере установка может отличаться. Если нужного пункта нет, откройте эту же ссылку в Edge или Chrome.</p>' +
      '<p><strong>Для заданий и отправки результатов нужен интернет. База Supabase должна быть подключена отдельно.</strong></p>' +
      '<p id="pwaNote" role="status"></p><div class="dialog-actions"><button type="button" id="pwaClose">Понятно</button></div>';
    document.body.appendChild(el);
    el.querySelector('#pwaNote').textContent = message || '';
    el.querySelector('#pwaClose').onclick = () => el.close();
    if (!el.open) el.showModal();
  }
  window.addEventListener('beforeinstallprompt', event => {
    event.preventDefault(); pending = event; paint();
  });
  window.addEventListener('appinstalled', () => { installed = true; pending = null; paint(); });
  mode.addEventListener?.('change', paint);
  button.addEventListener('click', async () => {
    if (!pending) { help(); return; }
    const prompt = pending; pending = null;
    button.disabled = true;
    try {
      await prompt.prompt();
      const choice = await prompt.userChoice;
      if (choice.outcome === 'accepted') button.hidden = true;
    } catch { help('Браузер не смог открыть окно установки. Используйте установку через его меню.'); }
    finally { button.disabled = false; }
  });
  paint();
  if ('serviceWorker' in navigator && window.isSecureContext) {
    navigator.serviceWorker.register('./sw.js', {scope:'./', updateViaCache:'none'}).catch(() => {
      button.title = 'Если установка недоступна, обновите страницу при подключённом интернете.';
    });
  }
})();

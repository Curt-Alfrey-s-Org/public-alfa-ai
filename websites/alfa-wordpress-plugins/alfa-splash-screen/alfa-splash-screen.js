(function () {
  'use strict';

  var root = document.getElementById('alfa-splash-root');
  if (!root) return;

  var key =
    (typeof window.ALFA_SPLASH !== 'undefined' && window.ALFA_SPLASH.sessionKey) ||
    'alfa_qd_splash_dismissed';

  function dismiss() {
    try {
      sessionStorage.setItem(key, '1');
    } catch (e) {
      /* ignore */
    }
    root.setAttribute('hidden', '');
    root.setAttribute('aria-hidden', 'true');
    document.body.classList.remove('alfa-splash-active');
    document.body.classList.remove('alfa-splash-pending');
  }

  function show() {
    root.removeAttribute('hidden');
    root.setAttribute('aria-hidden', 'false');
    document.body.classList.add('alfa-splash-active');
    document.body.classList.remove('alfa-splash-pending');
  }

  try {
    if (sessionStorage.getItem(key) === '1') {
      dismiss();
      return;
    }
  } catch (e) {
    /* show splash if storage blocked */
  }

  show();

  var enter = document.getElementById('alfa-splash-enter');
  if (enter) {
    enter.addEventListener('click', dismiss);
  }

  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape' && !root.hasAttribute('hidden')) {
      dismiss();
    }
  });
})();

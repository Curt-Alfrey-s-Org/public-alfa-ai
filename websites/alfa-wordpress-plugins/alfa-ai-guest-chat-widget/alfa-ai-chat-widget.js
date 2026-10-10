/* ALFa AI guest chat — canonical client for all WordPress sites.
 * POST /alfa-ai/api/guest/chat with { messages, stream: false }
 * Optional email relay when relayEndpoint is configured in ALFA_AI_CHAT.
 *
 * Dock chrome matches contracts-bot AlfaAskAiDock: closed pill launcher,
 * open fixed-size panel, popup 520x720, fullscreen (Esc).
 * Popup window features: https://developer.mozilla.org/en-US/docs/Web/API/Window/open
 */
(function () {
  'use strict';

  if (typeof window.ALFA_AI_CHAT === 'undefined') return;

  function initWidget(root) {
    if (!root || root.dataset.alfaChatInit === '1') return;
    root.dataset.alfaChatInit = '1';

    var CFG = window.ALFA_AI_CHAT;
    var form = root.querySelector('.alfa-ai-chat__form');
    var input = root.querySelector('.alfa-ai-chat__input');
    var log = root.querySelector('.alfa-ai-chat__log');
    var send = root.querySelector('.alfa-ai-chat__send');
    if (!form || !input || !log || !send) return;

    var history = [];
    var avatarUrl =
      CFG.avatarUrl ||
      'https://www.example.com/alfa-ai/branding/alfa-ai-avatar.png';

    function appendBubble(role, text) {
      if (role === 'error') {
        var err = document.createElement('div');
        err.className = 'alfa-ai-chat__bubble alfa-ai-chat__bubble--error';
        err.textContent = text;
        log.appendChild(err);
        log.scrollTop = log.scrollHeight;
        return err;
      }

      var row = document.createElement('div');
      row.className = 'alfa-ai-chat__msg-row alfa-ai-chat__msg-row--' + role;

      if (role === 'assistant') {
        var img = document.createElement('img');
        img.className = 'alfa-ai-chat__msg-avatar';
        img.src = avatarUrl;
        img.alt = '';
        img.width = 32;
        img.height = 32;
        row.appendChild(img);
      }

      var bubble = document.createElement('div');
      bubble.className = 'alfa-ai-chat__bubble alfa-ai-chat__bubble--' + role;
      bubble.textContent = text;
      row.appendChild(bubble);
      log.appendChild(row);
      log.scrollTop = log.scrollHeight;
      return row;
    }

    function resizeInput() {
      input.style.height = 'auto';
      var next = Math.min(input.scrollHeight, 128);
      input.style.height = next + 'px';
      input.style.overflowY = input.scrollHeight > 128 ? 'auto' : 'hidden';
    }

    input.addEventListener('keydown', function (e) {
      if (e.key === 'Enter' && !e.shiftKey) {
        e.preventDefault();
        form.requestSubmit();
      }
    });

    input.addEventListener('input', resizeInput);

    function extractEmail(text) {
      var m = String(text).match(/[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/);
      return m ? m[0] : null;
    }

    function findVisitorEmail() {
      for (var i = history.length - 1; i >= 0; i--) {
        if (history[i].role !== 'user') continue;
        var e = extractEmail(history[i].content);
        if (e) return e;
      }
      return null;
    }

    function findVisitorQuestion(visitorEmail) {
      for (var i = history.length - 1; i >= 0; i--) {
        if (history[i].role !== 'user') continue;
        var c = history[i].content;
        if (visitorEmail && c.indexOf(visitorEmail) !== -1 && c.length < visitorEmail.length + 50) {
          continue;
        }
        return c;
      }
      return '(no question captured)';
    }

    function showError(msg) {
      appendBubble('error', msg);
    }

    async function callAlfaAi() {
      var primer = CFG.primer || [];
      var maxTotal = parseInt(CFG.guestMaxMessages, 10) || 6;
      var room = Math.max(1, maxTotal - primer.length);
      var messages = primer.concat(history.slice(-room));
      var resp = await fetch(CFG.alfaAiEndpoint, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        credentials: 'same-origin',
        body: JSON.stringify({ messages: messages, stream: false }),
      });
      if (resp.status === 429) {
        throw new Error('Message limit reached for this hour. Please try again later.');
      }
      if (!resp.ok) {
        throw new Error('The AI is temporarily unavailable. Please try again later.');
      }
      var data = await resp.json();
      return String((((data.choices || [])[0] || {}).message || {}).content || '').trim();
    }

    async function relayToOwner(email, question) {
      if (!CFG.relayEndpoint) return false;
      var headers = { 'Content-Type': 'application/json' };
      if (CFG.nonce) headers['X-WP-Nonce'] = CFG.nonce;
      var resp = await fetch(CFG.relayEndpoint, {
        method: 'POST',
        headers: headers,
        credentials: 'same-origin',
        body: JSON.stringify({
          email: email,
          question: question,
          transcript: history.map(function (m) {
            return (m.role === 'user' ? 'Visitor: ' : 'AI: ') + m.content;
          }).join('\n\n'),
        }),
      });
      return resp.ok;
    }

    form.addEventListener('submit', async function (e) {
      e.preventDefault();
      var text = input.value.trim();
      if (!text) return;

      appendBubble('user', text);
      history.push({ role: 'user', content: text });
      input.value = '';
      resizeInput();
      send.disabled = true;
      var thinking = appendBubble('assistant', '...');

      try {
        var reply = await callAlfaAi();
        thinking.remove();

        var token = CFG.relayToken || '';
        if (token && reply.indexOf(token) !== -1) {
          var visible = reply.replace(token, '').trim();
          if (visible) appendBubble('assistant', visible);
          history.push({ role: 'assistant', content: visible });

          if (!CFG.relayEndpoint) {
            showError('Please use the Contact page to reach us.');
            return;
          }

          var email = findVisitorEmail();
          var question = findVisitorQuestion(email);
          if (!email) {
            showError('Please type your email address so we can follow up.');
          } else if (await relayToOwner(email, question)) {
            appendBubble('assistant', 'Your message was sent. We will reply to ' + email + '.');
          } else {
            showError('Could not send your message. Please use the Contact page.');
          }
        } else {
          appendBubble('assistant', reply || '(no response)');
          history.push({ role: 'assistant', content: reply });
        }
      } catch (err) {
        thinking.remove();
        showError(err.message || 'Unexpected error.');
      } finally {
        send.disabled = false;
        input.focus();
      }
    });
  }

  function initAll() {
    document.querySelectorAll('.alfa-ai-chat').forEach(initWidget);
  }

  function setupDockChrome() {
    var dock = document.getElementById('alfa-ai-dock');
    if (!dock || dock.dataset.alfaDockInit === '1') return;
    dock.dataset.alfaDockInit = '1';

    var CFG = window.ALFA_AI_CHAT;
    var panel = document.getElementById('alfa-ai-chat-panel');
    var fab = document.getElementById('alfa-ai-chat-fab');
    var closeBtn = dock.querySelector('.alfa-ai-chat__close');
    var popupBtn = document.getElementById('alfa-ai-chat-popup');
    var fullscreenBtn = document.getElementById('alfa-ai-chat-fullscreen');

    function focusInput() {
      var input = panel && panel.querySelector('.alfa-ai-chat__input');
      if (input) input.focus();
    }

    function setFullscreen(on) {
      if (!panel) return;
      if (on) {
        panel.classList.add('is-fullscreen');
      } else {
        panel.classList.remove('is-fullscreen');
      }
    }

    function openPanel() {
      if (!panel) return;
      panel.classList.add('is-open');
      panel.setAttribute('aria-hidden', 'false');
      dock.classList.add('is-panel-open');
      if (fab) fab.setAttribute('aria-expanded', 'true');
      initAll();
      focusInput();
    }

    function closePanel() {
      if (!panel) return;
      if (panel.classList.contains('is-fullscreen')) {
        setFullscreen(false);
        focusInput();
        return;
      }
      if (CFG.isPopup === '1') {
        window.close();
        return;
      }
      panel.classList.remove('is-open');
      panel.setAttribute('aria-hidden', 'true');
      dock.classList.remove('is-panel-open');
      if (fab) fab.setAttribute('aria-expanded', 'false');
    }

    function openPopup() {
      var w = 520;
      var h = 720;
      var left = Math.max(0, window.screenX + window.outerWidth - w - 24);
      var top = Math.max(0, window.screenY + 24);
      var url = new URL(window.location.href);
      url.searchParams.set('alfa_ai_popup', '1');
      window.open(
        url.toString(),
        'alfa-ai-chat',
        'width=' + w + ',height=' + h + ',left=' + left + ',top=' + top +
          ',menubar=no,toolbar=no,location=no,status=no,resizable=yes,scrollbars=yes'
      );
    }

    if (fab) {
      fab.addEventListener('click', function () {
        openPanel();
      });
    }
    if (closeBtn) {
      closeBtn.addEventListener('click', function () {
        closePanel();
      });
    }
    if (popupBtn) {
      popupBtn.addEventListener('click', function () {
        openPopup();
      });
    }
    if (fullscreenBtn) {
      fullscreenBtn.addEventListener('click', function () {
        setFullscreen(true);
        focusInput();
      });
    }

    document.addEventListener('keydown', function (e) {
      if (e.key !== 'Escape') return;
      if (!panel || !panel.classList.contains('is-open')) return;
      closePanel();
    });

    try {
      window.localStorage.removeItem('alfa_chat_collapsed');
    } catch (e) {
      /* ignore */
    }

    if (CFG.isPopup === '1' || (panel && panel.classList.contains('is-open'))) {
      openPanel();
    }
  }

  function boot() {
    setupDockChrome();
    initAll();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();

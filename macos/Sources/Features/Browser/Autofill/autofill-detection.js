(function () {
  'use strict';

  if (window.__tridentAutofillDetectionActive) return;
  window.__tridentAutofillDetectionActive = true;

  function postToNative(msg) {
    try {
      window.webkit.messageHandlers.autofill.postMessage(msg);
    } catch (e) {}
  }

  function isVisible(el) {
    return el.offsetParent !== null || el.offsetWidth > 0 || el.offsetHeight > 0;
  }

  var USERNAME_SELECTORS = [
    'input[autocomplete="username"]',
    'input[autocomplete="email"]',
    'input[type="email"]',
    'input[type="text"]'
  ];

  function findUsernameField(passwordField) {
    var root = passwordField.closest('form') || document.body;
    var candidates = Array.from(root.querySelectorAll(USERNAME_SELECTORS.join(',')));
    candidates = candidates.filter(function (c) {
      return !!(c.compareDocumentPosition(passwordField) & Node.DOCUMENT_POSITION_FOLLOWING);
    });
    return candidates.length > 0 ? candidates[candidates.length - 1] : null;
  }

  function buildSelector(el) {
    if (el.id) return '#' + CSS.escape(el.id);
    if (el.name) return el.tagName.toLowerCase() + '[name="' + el.name + '"]';
    var parts = [];
    var node = el;
    while (node && node !== document.body) {
      var parent = node.parentElement;
      if (!parent) break;
      var siblings = Array.from(parent.children).filter(function (c) {
        return c.tagName === node.tagName;
      });
      var idx = siblings.indexOf(node) + 1;
      parts.unshift(node.tagName.toLowerCase() + ':nth-of-type(' + idx + ')');
      node = parent;
    }
    return parts.join(' > ');
  }

  function isNewPasswordField(el) {
    return el.getAttribute('autocomplete') === 'new-password';
  }

  function scanForms() {
    var passwordFields = Array.from(document.querySelectorAll('input[type="password"]'))
      .filter(isVisible);

    if (passwordFields.length === 0) return null;

    var forms = [];
    var seen = new Set();
    var formIndex = 0;

    passwordFields.forEach(function (pwField) {
      var root = pwField.closest('form') || document.body;
      if (seen.has(root)) return;
      seen.add(root);

      var usernameField = findUsernameField(pwField);
      var hasNewPassword = isNewPasswordField(pwField);

      var allPasswords = Array.from(root.querySelectorAll('input[type="password"]')).filter(isVisible);
      if (allPasswords.length >= 2) {
        hasNewPassword = true;
      }

      var form = {
        formId: 'auto-' + formIndex++,
        hasPassword: true,
        hasNewPassword: hasNewPassword,
        usernameSelector: usernameField ? buildSelector(usernameField) : null,
        passwordSelector: buildSelector(pwField)
      };

      forms.push(form);

      [usernameField, pwField].forEach(function (field) {
        if (!field) return;
        if (field.__tridentFocusTracked) return;
        field.__tridentFocusTracked = true;
        field.addEventListener('focus', function () {
          postToNative({ kind: 'fieldFocused', formId: form.formId });
        });
      });
    });

    return forms.length > 0 ? forms : null;
  }

  var scanTimer = null;

  function scheduleScan() {
    clearTimeout(scanTimer);
    scanTimer = setTimeout(function () {
      var forms = scanForms();
      if (forms) {
        postToNative({ kind: 'formDetected', forms: forms });
      }
    }, 500);
  }

  function attachSubmitListeners() {
    document.querySelectorAll('form').forEach(function (form) {
      if (form.__tridentSubmitTracked) return;
      form.__tridentSubmitTracked = true;

      form.addEventListener('submit', function () {
        var pwField = form.querySelector('input[type="password"]');
        if (!pwField || !pwField.value) return;

        var allPasswords = Array.from(form.querySelectorAll('input[type="password"]')).filter(isVisible);
        var isNewPassword = allPasswords.length >= 2 ||
          allPasswords.some(function (f) { return f.getAttribute('autocomplete') === 'new-password'; });

        var usernameField = findUsernameField(pwField);
        var username = usernameField ? usernameField.value : '';

        postToNative({
          kind: 'submitDetected',
          username: username,
          password: pwField.value,
          isNewPassword: isNewPassword
        });
      });
    });
  }

  var observer = new MutationObserver(function () {
    scheduleScan();
    attachSubmitListeners();
  });

  observer.observe(document.body, { childList: true, subtree: true });

  scheduleScan();
  attachSubmitListeners();

})();

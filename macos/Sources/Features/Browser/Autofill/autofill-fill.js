// Fill helper — injected into WKContentWorld.defaultClient.
// Isolated from page JavaScript so page scripts cannot intercept
// our fill function or its arguments (though filled DOM values
// remain visible to all worlds — accepted trade-off).

window.__tridentAutofillHelper = {
  /**
   * Fill a single input field identified by `selector` with `value`.
   * Uses the native HTMLInputElement setter so that React, Angular, and
   * other frameworks that replace the property descriptor pick up the change.
   * Fires both 'input' and 'change' events to trigger framework listeners.
   *
   * @param {string} selector - CSS selector for the target input
   * @param {string} value    - Value to set
   * @returns {boolean} true if the field was found and filled
   */
  fill: function (selector, value) {
    var el = document.querySelector(selector);
    if (!el) return false;

    // Use the native setter, bypassing any framework wrappers on the
    // prototype — same technique used by Cypress, Playwright, etc.
    var nativeSetter = Object.getOwnPropertyDescriptor(
      HTMLInputElement.prototype,
      'value'
    ).set;
    nativeSetter.call(el, value);

    // Dispatch input and change events so React/Angular/Vue re-render
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));

    return true;
  }
};

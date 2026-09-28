(function () {
  "use strict";
  var BTN_ID = "nc-sso-login-btn";
  var SSO_URL = "/sso/OID/start/nextcloud";

  function isLoginView() {
    var h = location.hash || "";
    return h.indexOf("/login") !== -1 || h === "" || h === "#";
  }

  function ensureButton() {
    var existing = document.getElementById(BTN_ID);
    if (!isLoginView()) {
      if (existing) existing.remove();
      return;
    }
    if (existing) return;
    var a = document.createElement("a");
    a.id = BTN_ID;
    a.href = SSO_URL;
    a.textContent = "Accedi con Nextcloud (SSO)";
    a.style.cssText = [
      "position:fixed",
      "bottom:24px",
      "right:24px",
      "z-index:2147483647",
      "background:#00A4DC",
      "color:#fff",
      "padding:12px 20px",
      "border-radius:4px",
      "font-family:sans-serif",
      "font-size:14px",
      "font-weight:bold",
      "text-decoration:none",
      "box-shadow:0 2px 8px rgba(0,0,0,.35)"
    ].join(";");
    document.body.appendChild(a);
  }

  window.addEventListener("hashchange", ensureButton);
  document.addEventListener("DOMContentLoaded", ensureButton);
  setInterval(ensureButton, 1000);
})();

// The background worker stored the full conversation HTML under a key passed in
// the URL hash. We fetch it and inject it WITHOUT document.write (which would
// re-trigger CSP on any inline scripts). We set innerHTML on a container and
// wire up copy buttons here, since the injected HTML's own inline script would
// be blocked by the extension Content Security Policy.
(function () {
  const fb = document.getElementById('fallback');
  const root = document.getElementById('root');
  function fail(msg) { if (fb) fb.textContent = msg; }

  if (typeof chrome === 'undefined' || !chrome.storage) {
    fail('Extension storage unavailable. Re-run the export.');
    return;
  }

  const key = decodeURIComponent((location.hash || '').replace(/^#/, ''));
  const lookup = key ? { [key]: '', viewerLatest: '' } : { viewerLatest: '' };

  chrome.storage.local.get(lookup, (res) => {
    if (chrome.runtime.lastError) { fail('Storage error: ' + chrome.runtime.lastError.message); return; }
    const realKey = key || res.viewerLatest;
    const fullHtml = realKey ? res[realKey] : '';
    if (!fullHtml) { fail('No conversation data found. Run an export and click “Open in tab”.'); return; }

    // Pull just the <body> inner part and the <style> from the generated page,
    // so we can inject it into our existing document without document.write.
    let styleHtml = '';
    const styleMatch = fullHtml.match(/<style>([\s\S]*?)<\/style>/i);
    if (styleMatch) styleHtml = `<style>${styleMatch[1]}</style>`;

    let bodyHtml = fullHtml;
    const bodyMatch = fullHtml.match(/<body[^>]*>([\s\S]*?)<\/body>/i);
    if (bodyMatch) bodyHtml = bodyMatch[1];
    // Strip any <script> tags from the injected fragment (they'd be CSP-blocked anyway).
    bodyHtml = bodyHtml.replace(/<script[\s\S]*?<\/script>/gi, '');

    if (fb) fb.style.display = 'none';
    root.innerHTML = styleHtml + bodyHtml;

    // Delegated copy-path handler (replaces the injected page's inline script).
    root.addEventListener('click', (e) => {
      const btn = e.target.closest('.copy');
      if (!btn) return;
      const target = document.getElementById(btn.dataset.target);
      if (!target) return;
      navigator.clipboard.writeText(target.textContent).then(() => {
        const orig = btn.textContent;
        btn.textContent = 'Copied ✓';
        setTimeout(() => { btn.textContent = orig; }, 1500);
      });
    });

    if (realKey && realKey.startsWith('viewerHtml:')) {
      chrome.storage.local.remove(realKey);
    }
  });
})();

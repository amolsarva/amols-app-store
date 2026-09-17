const $ = (id) => document.getElementById(id);

try {
  $('ver').textContent = 'v' + (chrome.runtime.getManifest().version);
} catch (_) {}

function render(p) {
  if (!p) return;
  $('status-text').textContent = p.status || 'Working…';
  $('msgs').textContent = (p.total ?? 0).toLocaleString();
  $('pass').textContent = p.pass ?? 0;
  if (Array.isArray(p.log)) $('log').textContent = p.log.slice(-40).join('\n');

  function fmt(ms) { return ms == null ? '—' : new Date(ms).toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' }); }
  if (p.earliest != null || p.latest != null) {
    $('range').textContent = fmt(p.earliest) + ' → ' + fmt(p.latest);
    $('range-box').style.display = '';
  }

  const done = p.phase === 'done' || p.phase === 'stopped';
  $('pulse').classList.toggle('done', done);
  $('bar').classList.toggle('done', done);
  let pct = done ? 100 : Math.min(90, 5 + (p.stable || 0) / 20 * 70 + Math.min(15, (p.pass || 0) / 4));
  $('bar-fill').style.width = pct + '%';
}

if (typeof chrome !== 'undefined' && chrome.storage) {
  chrome.storage.local.get({ exportProgress: null }, (r) => render(r.exportProgress));
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area === 'local' && changes.exportProgress) render(changes.exportProgress.newValue);
  });
} else {
  $('status-text').textContent = 'Extension storage unavailable.';
}

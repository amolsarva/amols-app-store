// Will be filled from storage before renderTimeline runs
let OUTPUT_FOLDER_NAME = 'your export folder';

// Absolute path to the folder that CONTAINS your export folder, so we can show
// full copy-pasteable paths and a "reveal in Finder" command. The browser can't
// learn this automatically (File System Access hides the OS path), so it's a
// one-time setting; this is a sensible default for this machine.
let BASE_PATH = '/Users/MrAnonymous/Documents/root';

function absPath(rel) {
  const base = (BASE_PATH || '').replace(/\/+$/, '');
  return base ? `${base}/${rel}` : rel;
}
function shellQuote(p) { return `"${String(p).replace(/"/g, '\\"')}"`; }

// Show the real version everywhere (single source of truth = manifest).
let EXT_VERSION = '';
try { EXT_VERSION = chrome.runtime.getManifest().version; } catch (_) {}
if (EXT_VERSION) {
  const verEl = document.getElementById('ver');
  if (verEl) verEl.textContent = 'v' + EXT_VERSION;
  document.title = `Google Voice Export History (v${EXT_VERSION})`;
}

function relTime(iso) {
  const delta = (Date.now() - new Date(iso)) / 1000;
  if (delta < 60) return 'just now';
  if (delta < 3600) return `${Math.floor(delta / 60)}m ago`;
  if (delta < 86400) return `${Math.floor(delta / 3600)}h ago`;
  if (delta < 7 * 86400) return `${Math.floor(delta / 86400)}d ago`;
  return new Date(iso).toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' });
}

function absTime(iso) {
  return new Date(iso).toLocaleString(undefined, {
    weekday: 'short', month: 'short', day: 'numeric',
    hour: 'numeric', minute: '2-digit',
  });
}

function formatExt(fmt) {
  return (fmt || 'json').toUpperCase();
}

function fileIcon(fmt) {
  if (fmt === 'csv') return '📊';
  if (fmt === 'txt') return '📄';
  return '📋';
}

function escAttr(s) {
  return String(s ?? '').replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function renderStats(history) {
  const totalRuns = history.length;
  const totalMsgs = history.reduce((n, r) => n + (r.messageCount || 0), 0);
  const totalImgs = history.reduce((n, r) => n + (r.imageCount || 0), 0);
  const phones = new Set(history.map((r) => r.digits).filter(Boolean)).size;

  const stats = [
    { value: totalRuns, label: 'Total exports', color: '#4f8ef7' },
    { value: totalMsgs.toLocaleString(), label: 'Messages exported', color: '#34d399' },
    { value: totalImgs.toLocaleString(), label: 'Images found', color: '#a78bfa' },
    { value: phones, label: 'Unique contacts', color: '#fbbf24' },
  ];

  document.getElementById('stats-row').innerHTML = stats.map((s) => `
    <div class="stat">
      <div class="stat-value" style="color:${s.color}">${s.value}</div>
      <div class="stat-label">${s.label}</div>
    </div>
  `).join('');

  document.getElementById('subtitle').textContent =
    `${totalRuns} export${totalRuns !== 1 ? 's' : ''} · last updated ${relTime(history[0]?.exportedAt || new Date().toISOString())}`
    + (EXT_VERSION ? ` · v${EXT_VERSION}` : '');
}

function renderTimeline(history) {
  const container = document.getElementById('timeline');

  if (history.length === 0) {
    container.innerHTML = `
      <div class="empty">
        <div class="empty-icon">📭</div>
        <h2>No exports yet</h2>
        <p>Open a Google Voice conversation and click "Export open thread" in the extension popup.</p>
      </div>`;
    return;
  }

  container.innerHTML = history.map((run, i) => {
    const hasImages = run.imageCount > 0;
    const dataFilename = run.filename || `google-voice-thread-*.${run.format || 'json'}`;
    const folderRoot = run.folderName || OUTPUT_FOLDER_NAME;
    const dataPath = absPath(`${folderRoot}/${dataFilename}`);
    const imgFolder = run.imageSubfolder ? absPath(`${folderRoot}/${run.imageSubfolder}`) : null;
    const dataReveal = `open -R ${shellQuote(dataPath)}`;
    const imgReveal = imgFolder ? `open ${shellQuote(imgFolder)}` : null;

    return `
      <div class="run" id="run-${i}">
        <div class="run-header" data-toggle="${i}">
          <div class="run-icon sms">💬</div>
          <div class="run-meta">
            <div class="run-phone">${run.phone || 'Unknown contact'}</div>
            <div class="run-time">${absTime(run.exportedAt)} · ${relTime(run.exportedAt)}</div>
          </div>
          <div class="run-badges">
            <span class="badge msgs">💬 ${(run.messageCount || 0).toLocaleString()} msgs</span>
            ${hasImages ? `<span class="badge imgs">🖼 ${run.imageCount} images</span>` : ''}
            <span class="badge fmt">${formatExt(run.format)}</span>
          </div>
          <span class="chevron">▶</span>
        </div>
        <div class="run-body">
          <div class="run-body-inner">

            <div>
              <div class="section-label">Exported file</div>
              <a class="file-link" href="#" data-copy="${escAttr(dataPath)}" title="Click to copy full path">
                <span class="file-icon">${fileIcon(run.format)}</span>
                <div class="file-link-info">
                  <div class="file-link-name">${dataFilename}</div>
                  <div class="file-link-path">${dataPath}</div>
                </div>
                <span class="file-link-arrow" title="Click to copy path">📋</span>
              </a>
              <div class="path-actions">
                <button class="mini" data-copy="${escAttr(dataPath)}">📋 Copy full path</button>
                <button class="mini" data-reveal="${escAttr(dataReveal)}">🔍 Copy “reveal in Finder” command</button>
              </div>
            </div>

            ${hasImages && imgFolder ? `
            <div>
              <div class="section-label">Images folder</div>
              <a class="file-link" href="#" data-copy="${escAttr(imgFolder)}" title="Click to copy full path">
                <span class="file-icon">🖼️</span>
                <div class="file-link-info">
                  <div class="file-link-name">${run.imageCount} image${run.imageCount !== 1 ? 's' : ''}</div>
                  <div class="file-link-path">${imgFolder}</div>
                </div>
                <span class="file-link-arrow" title="Click to copy path">📋</span>
              </a>
              <div class="path-actions">
                <button class="mini" data-copy="${escAttr(imgFolder)}">📋 Copy folder path</button>
                <button class="mini" data-reveal="${escAttr(imgReveal)}">📂 Copy “open folder” command</button>
              </div>
            </div>` : ''}

            <div class="meta-grid">
              <div class="meta-item">
                <div class="meta-item-label">Messages exported</div>
                <div class="meta-item-value">${(run.messageCount || 0).toLocaleString()}</div>
              </div>
              <div class="meta-item">
                <div class="meta-item-label">Total in thread</div>
                <div class="meta-item-value">${(run.totalMessages || run.messageCount || 0).toLocaleString()}</div>
              </div>
              <div class="meta-item">
                <div class="meta-item-label">Format</div>
                <div class="meta-item-value">${formatExt(run.format)}</div>
              </div>
              ${run.coverage ? `
              <div class="meta-item">
                <div class="meta-item-label">📅 Dates covered</div>
                <div class="meta-item-value">${run.coverage}</div>
              </div>` : ''}
              ${run.addedThisRun != null ? `
              <div class="meta-item">
                <div class="meta-item-label">New this run</div>
                <div class="meta-item-value">+${run.addedThisRun.toLocaleString()}</div>
              </div>` : ''}
              ${run.filter ? `
              <div class="meta-item">
                <div class="meta-item-label">Filter applied</div>
                <div class="meta-item-value">"${run.filter}"</div>
              </div>` : ''}
            </div>

            ${run.sourceUrl ? `
            <div>
              <a class="source-link" href="${run.sourceUrl}" target="_blank">
                🔗 Open original thread in Google Voice
              </a>
            </div>` : ''}

          </div>
        </div>
      </div>
    `;
  }).join('');

  // Auto-open the first (most recent) run
  toggleRun(0);
}

function toggleRun(i) {
  const el = document.getElementById(`run-${i}`);
  if (el) el.classList.toggle('open');
}

let copiedTimeout;
function copyPath(path, arrow) {
  navigator.clipboard.writeText(path).then(() => {
    if (arrow) {
      arrow.textContent = '✅';
      clearTimeout(copiedTimeout);
      copiedTimeout = setTimeout(() => { arrow.textContent = '📋'; }, 1800);
    }
  });
}

function flashButton(btn) {
  const orig = btn.textContent;
  btn.textContent = '✅ Copied — paste into Terminal/app';
  setTimeout(() => { btn.textContent = orig; }, 1900);
}

// Delegated clicks (MV3 CSP forbids inline onclick attributes).
document.getElementById('timeline').addEventListener('click', (e) => {
  // Mini action buttons take priority (they carry their own data-copy/data-reveal).
  const btn = e.target.closest('button.mini');
  if (btn) {
    e.preventDefault();
    const text = btn.dataset.reveal || btn.dataset.copy;
    navigator.clipboard.writeText(text).then(() => flashButton(btn));
    return;
  }
  const header = e.target.closest('[data-toggle]');
  if (header) { toggleRun(Number(header.dataset.toggle)); return; }
  const link = e.target.closest('[data-copy]');
  if (link) {
    e.preventDefault();
    copyPath(link.dataset.copy, link.querySelector('.file-link-arrow'));
  }
});

document.getElementById('reload-btn').addEventListener('click', () => { load(); });

// Let the user set the absolute base folder path (used for full paths + reveal commands).
const setPathBtn = document.getElementById('setpath-btn');
if (setPathBtn) {
  setPathBtn.addEventListener('click', () => {
    const v = prompt(
      'Absolute path to the folder that CONTAINS your export folder.\n' +
      'Example: /Users/you/Documents/root\n' +
      '(Your exports live inside this, under "' + OUTPUT_FOLDER_NAME + '/")',
      BASE_PATH
    );
    if (v == null) return;
    BASE_PATH = v.trim().replace(/\/+$/, '');
    if (chrome?.storage) chrome.storage.local.set({ outputFolderPath: BASE_PATH });
    load();
  });
}

function decodeHashPayload() {
  let raw = (location.hash || '').replace(/^#/, '').trim();
  if (!raw) return null;
  try {
    raw = decodeURIComponent(raw);
  } catch (_) { /* not URL-encoded; use as-is */ }
  raw = raw.replace(/-/g, '+').replace(/_/g, '/');
  while (raw.length % 4) raw += '=';
  try {
    const json = decodeURIComponent(escape(atob(raw)));
    return JSON.parse(json);
  } catch (e) {
    try {
      return JSON.parse(location.hash.replace(/^#/, ''));
    } catch (_) {
      console.warn('[GV-Exporter] Could not decode hash payload:', e.message);
      return null;
    }
  }
}

function applyData(exportHistory, outputFolderName) {
  exportHistory = Array.isArray(exportHistory) ? exportHistory : [];
  if (outputFolderName) {
    OUTPUT_FOLDER_NAME = outputFolderName;
    const badge = document.getElementById('folder-badge');
    document.getElementById('folder-badge-name').textContent = outputFolderName;
    badge.style.display = 'flex';
  }
  try {
    renderStats(exportHistory);
    renderTimeline(exportHistory);
  } catch (err) {
    console.error('[GV-Exporter] render failed:', err);
    document.getElementById('timeline').innerHTML =
      `<div class="empty"><div class="empty-icon">⚠️</div><h2>Could not render some exports</h2><p>${err.message}</p></div>`;
  }
}

function load() {
  const timeline = document.getElementById('timeline');
  timeline.innerHTML = `<div class="empty"><div class="empty-icon" style="font-size:32px">⏳</div><p>Loading…</p></div>`;

  try {
    const hashData = decodeHashPayload();
    if (hashData && (Array.isArray(hashData.exportHistory) || Array.isArray(hashData))) {
      const history = Array.isArray(hashData) ? hashData : hashData.exportHistory;
      applyData(history, hashData.outputFolderName || '');
      return;
    }

    if (typeof chrome === 'undefined' || !chrome.storage) {
      timeline.innerHTML = `<div class="empty"><div class="empty-icon">⚠️</div><h2>No export data found</h2>
        <p>This page opens automatically after an export. If you reached it directly, run an export first.</p></div>`;
      return;
    }

    let attempts = 0;
    const readStorage = () => {
      chrome.storage.local.get({ exportHistory: [], outputFolderName: '', outputFolderPath: '' }, (result) => {
        if (chrome.runtime.lastError) {
          timeline.innerHTML = `<div class="empty"><div class="empty-icon">⚠️</div><h2>Storage error</h2><p>${chrome.runtime.lastError.message}</p></div>`;
          return;
        }
        if (result.outputFolderPath) BASE_PATH = result.outputFolderPath;
        const history = Array.isArray(result.exportHistory) ? result.exportHistory : [];
        if (history.length === 0 && attempts < 4) {
          attempts++;
          setTimeout(readStorage, 300);
          return;
        }
        applyData(history, result.outputFolderName);
      });
    };
    readStorage();
  } catch (err) {
    timeline.innerHTML = `<div class="empty"><div class="empty-icon">⚠️</div><h2>Could not render export</h2><p>${err.message}</p></div>`;
    console.error('[GV-Exporter] history load failed:', err);
  }
}

document.getElementById('clear-btn').addEventListener('click', () => {
  if (!confirm('Clear all export history? (Your exported files are not affected.)')) return;
  chrome.storage.local.remove('exportHistory', () => {
    renderStats([]);
    renderTimeline([]);
  });
});

window.addEventListener('hashchange', load);

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', load);
} else {
  load();
}

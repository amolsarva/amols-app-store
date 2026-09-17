try {
  const v = document.getElementById('ver');
  if (v) v.textContent = 'v' + chrome.runtime.getManifest().version;
} catch (_) {}

const format = document.getElementById('format');
const filter = document.getElementById('filter');
const diffOnly = document.getElementById('diffOnly');
const exportButton = document.getElementById('export');
const resumeButton = document.getElementById('resume');
const stopButton = document.getElementById('stop');
const status = document.getElementById('status');
const checkpointInfo = document.getElementById('checkpoint-info');
const folderName = document.getElementById('folder-name');
const changeFolder = document.getElementById('change-folder');
const getNewerButton = document.getElementById('get-newer');
const getEarlierButton = document.getElementById('get-earlier');
const archiveBox = document.getElementById('archive-box');
const archiveText = document.getElementById('archive-text');
const resyncButton = document.getElementById('resync');

chrome.storage.local.get({ format: 'json', filter: '', diffOnly: false, outputFolderName: '' }, (settings) => {
  format.value = settings.format;
  filter.value = settings.filter;
  diffOnly.checked = settings.diffOnly;
  if (settings.outputFolderName) folderName.textContent = settings.outputFolderName;
});

changeFolder.addEventListener('click', async (e) => {
  e.preventDefault();
  status.textContent = 'Opening folder picker…';
  try {
    const response = await sendToTab('start-export', { changeFolder: true, dryRun: true });
    status.textContent = response?.message || 'Folder updated.';
    // Refresh displayed folder name
    chrome.storage.local.get({ outputFolderName: '' }, (s) => {
      if (s.outputFolderName) folderName.textContent = s.outputFolderName;
    });
  } catch (e) {
    status.textContent = e.message;
  }
});

function saveSettings() {
  chrome.storage.local.set({
    format: format.value,
    filter: filter.value.trim(),
    diffOnly: diffOnly.checked,
  });
}

async function getActiveVoiceTab() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab?.url?.startsWith('https://voice.google.com/')) {
    throw new Error('Open a Google Voice conversation tab first.');
  }
  return tab;
}

async function ensureContentScript(tabId) {
  try {
    await chrome.tabs.sendMessage(tabId, { type: 'ping' });
  } catch {
    // Content script not injected (e.g. extension was reloaded) — inject it now.
    await chrome.scripting.executeScript({ target: { tabId }, files: ['content.js'] });
    await chrome.scripting.insertCSS({ target: { tabId }, files: ['content.css'] });
    // Give it a moment to register its message listener.
    await new Promise((r) => setTimeout(r, 200));
  }
}

async function sendToTab(type, extra = {}) {
  saveSettings();
  const tab = await getActiveVoiceTab();
  await ensureContentScript(tab.id);
  return chrome.tabs.sendMessage(tab.id, {
    type,
    options: {
      format: format.value,
      filter: filter.value.trim(),
      diffOnly: diffOnly.checked,
      ...extra,
    },
  });
}

// Check for a saved checkpoint + existing archive on popup open
(async () => {
  try {
    const tab = await getActiveVoiceTab();

    const response = await chrome.tabs.sendMessage(tab.id, { type: 'check-checkpoint' });
    if (response?.checkpoint) {
      const { count, savedAt } = response.checkpoint;
      const date = new Date(savedAt).toLocaleString();
      checkpointInfo.textContent = `Checkpoint: ${count} messages saved at ${date}`;
      checkpointInfo.style.display = '';
      resumeButton.style.display = '';
    }

    // Existing archive for this contact → show coverage + newer/earlier options.
    const arch = await chrome.tabs.sendMessage(tab.id, { type: 'check-archive' });
    if (arch?.archive) {
      const a = arch.archive;
      archiveText.innerHTML =
        `📚 You already have <b>${a.count.toLocaleString()}</b> messages saved for this contact,<br>` +
        `covering <b>${a.earliestLabel}</b> → <b>${a.latestLabel}</b>.<br>` +
        `Get more recent or earlier history below.`;
      archiveBox.style.display = '';
      getNewerButton.style.display = '';
      getEarlierButton.style.display = '';
      exportButton.textContent = 'Re-scan entire thread';
    } else {
      // First run for this contact.
      exportButton.textContent = 'Export full history (start here)';
    }
  } catch (e) {
    if (e.message && !e.message.includes('Could not establish connection')) {
      status.textContent = e.message;
    }
  }
})();

async function runExport(mode, label) {
  status.textContent = `${label} Keep the Google Voice tab visible.`;
  [exportButton, getNewerButton, getEarlierButton].forEach((b) => (b.disabled = true));
  try {
    const response = await sendToTab('start-export', { resume: false, mode });
    status.textContent = response?.message || 'Export started.';
  } catch (error) {
    status.textContent = error.message;
  } finally {
    [exportButton, getNewerButton, getEarlierButton].forEach((b) => (b.disabled = false));
  }
}

getNewerButton.addEventListener('click', () => runExport('newer', 'Fetching newer messages…'));
getEarlierButton.addEventListener('click', () => runExport('earlier', 'Fetching earlier history…'));

exportButton.addEventListener('click', () => runExport('full', 'Scanning the whole thread…'));

// Re-sync images: fetch only the images missing from disk, using the saved
// archive — no re-scrolling. Needs the Voice tab (for Google session cookies).
resyncButton.addEventListener('click', async () => {
  status.textContent = 'Re-syncing images — keep the Google Voice tab visible…';
  resyncButton.disabled = true;
  try {
    const response = await sendToTab('resync-images');
    status.textContent = response?.message || 'Re-sync finished.';
  } catch (error) {
    status.textContent = error.message;
  } finally {
    resyncButton.disabled = false;
  }
});

resumeButton.addEventListener('click', async () => {
  status.textContent = 'Resuming from checkpoint…';
  resumeButton.disabled = true;
  exportButton.disabled = true;
  try {
    const response = await sendToTab('start-export', { resume: true });
    status.textContent = response?.message || 'Resume started.';
  } catch (error) {
    status.textContent = error.message;
  } finally {
    resumeButton.disabled = false;
    exportButton.disabled = false;
  }
});

document.getElementById('reload-ext').addEventListener('click', (e) => {
  e.preventDefault();
  chrome.runtime.reload();
});

stopButton.addEventListener('click', async () => {
  try {
    const response = await sendToTab('stop-export');
    status.textContent = response?.message || 'Stop requested.';
  } catch (error) {
    status.textContent = error.message;
  }
});

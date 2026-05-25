const format = document.getElementById('format');
const filter = document.getElementById('filter');
const diffOnly = document.getElementById('diffOnly');
const exportButton = document.getElementById('export');
const resumeButton = document.getElementById('resume');
const stopButton = document.getElementById('stop');
const status = document.getElementById('status');
const checkpointInfo = document.getElementById('checkpoint-info');

chrome.storage.local.get({ format: 'json', filter: '', diffOnly: false }, (settings) => {
  format.value = settings.format;
  filter.value = settings.filter;
  diffOnly.checked = settings.diffOnly;
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

async function sendToTab(type, extra = {}) {
  saveSettings();
  const tab = await getActiveVoiceTab();
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

// Check for a saved checkpoint on popup open
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
  } catch {
    // Tab not ready or not on voice.google.com — fine, just hide resume
  }
})();

exportButton.addEventListener('click', async () => {
  status.textContent = 'Starting export. Keep the Google Voice tab open.';
  exportButton.disabled = true;
  try {
    const response = await sendToTab('start-export', { resume: false });
    status.textContent = response?.message || 'Export started.';
  } catch (error) {
    status.textContent = error.message;
  } finally {
    exportButton.disabled = false;
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

stopButton.addEventListener('click', async () => {
  try {
    const response = await sendToTab('stop-export');
    status.textContent = response?.message || 'Stop requested.';
  } catch (error) {
    status.textContent = error.message;
  }
});

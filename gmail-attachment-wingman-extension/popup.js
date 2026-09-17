async function loadPayloads() {
  const [codeGs, indexHtml] = await Promise.all([
    fetch(chrome.runtime.getURL('code.gs.txt')).then(r => r.text()),
    fetch(chrome.runtime.getURL('index.html.txt')).then(r => r.text())
  ]);
  document.getElementById('codeGs').value = codeGs;
  document.getElementById('indexHtml').value = indexHtml;
}

function setStatus(msg) {
  document.getElementById('savedStatus').textContent = msg;
}

async function openUrl(url) {
  await chrome.tabs.create({ url });
}

document.getElementById('openNewScript').addEventListener('click', () => {
  openUrl('https://script.google.com/home/projects/create');
});

document.getElementById('openDashboard').addEventListener('click', () => {
  openUrl('https://script.google.com/home');
});

document.querySelectorAll('.copy').forEach(btn => {
  btn.addEventListener('click', async () => {
    const target = document.getElementById(btn.dataset.target);
    await navigator.clipboard.writeText(target.value);
    const old = btn.textContent;
    btn.textContent = 'Copied';
    setTimeout(() => btn.textContent = old, 900);
  });
});

document.querySelectorAll('.chip').forEach(btn => {
  btn.addEventListener('click', async () => {
    await navigator.clipboard.writeText(btn.dataset.copy);
    const old = btn.textContent;
    btn.textContent = 'copied';
    setTimeout(() => btn.textContent = old, 900);
  });
});

document.getElementById('saveWebAppUrl').addEventListener('click', async () => {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab || !tab.url) return setStatus('No active tab found.');
  if (!tab.url.startsWith('https://script.google.com/')) {
    return setStatus('Open your deployed Apps Script web app tab first, then click this.');
  }
  await chrome.storage.local.set({ webAppUrl: tab.url });
  setStatus('Saved this Apps Script URL for this Chrome profile.');
});

document.getElementById('openSavedWebApp').addEventListener('click', async () => {
  const { webAppUrl } = await chrome.storage.local.get('webAppUrl');
  if (!webAppUrl) return setStatus('No web app saved yet. Open it, then save current tab.');
  await openUrl(webAppUrl);
});

loadPayloads().catch(err => setStatus('Could not load bundled script text: ' + err.message));

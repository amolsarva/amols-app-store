const DEFAULTS = {
  meetUrl: "https://meet.google.com/",
  workUrl: "https://gtm.newaiyork.com/sandro-vonci-sunday-morning-call-20260526/",
  message: "Hey Sandro and Vonci, here is a call I wanted you to join that you missed on Sunday morning. Here is the recording.",
  audioUrl: "https://gtm.newaiyork.com/audio/the-more-you-ignore-me-the-closer-i-get-rare.mp3"
};

async function ensureDefaults() {
  const stored = await chrome.storage.local.get(Object.keys(DEFAULTS));
  const updates = {};
  for (const [key, value] of Object.entries(DEFAULTS)) {
    if (!stored[key]) updates[key] = value;
  }
  if (Object.keys(updates).length) {
    await chrome.storage.local.set(updates);
  }
}

async function openUrl(url, active = true) {
  if (!url) return null;
  return chrome.tabs.create({ url, active });
}

async function openSidecar(active = true) {
  return openUrl(chrome.runtime.getURL("sidecar.html"), active);
}

chrome.runtime.onInstalled.addListener(async ({ reason }) => {
  await ensureDefaults();
  if (reason === "install") {
    await chrome.tabs.create({ url: chrome.runtime.getURL("welcome.html"), active: true });
  }
});

chrome.runtime.onStartup.addListener(ensureDefaults);

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  (async () => {
    await ensureDefaults();
    if (message?.type === "open-meet") {
      const { meetUrl } = await chrome.storage.local.get("meetUrl");
      const tab = await openUrl(meetUrl || DEFAULTS.meetUrl, true);
      sendResponse({ ok: true, tabId: tab?.id });
      return;
    }
    if (message?.type === "open-work") {
      const { workUrl } = await chrome.storage.local.get("workUrl");
      const tab = await openUrl(workUrl || DEFAULTS.workUrl, true);
      sendResponse({ ok: true, tabId: tab?.id });
      return;
    }
    if (message?.type === "open-sidecar") {
      const tab = await openSidecar(true);
      sendResponse({ ok: true, tabId: tab?.id });
      return;
    }
    if (message?.type === "get-defaults") {
      const values = await chrome.storage.local.get(DEFAULTS);
      sendResponse({ ok: true, values });
      return;
    }
    sendResponse({ ok: false, error: "Unknown message" });
  })().catch((error) => sendResponse({ ok: false, error: error.message }));
  return true;
});

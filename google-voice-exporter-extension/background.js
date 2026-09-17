// ============================================================
// Background service worker
// Handles: chrome.downloads (content scripts can't in MV3)
//          opening the history tab
// ============================================================

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  // Download a text/JSON/CSV file — content passed as string, blob created here
  // so the blob URL is valid in the SW's origin context.
  if (message?.type === 'download-text') {
    const blob = new Blob([message.content], { type: `${message.mime};charset=utf-8` });
    const url = URL.createObjectURL(blob);
    chrome.downloads.download(
      { url, filename: message.filename, conflictAction: message.conflictAction || 'uniquify', saveAs: false },
      (downloadId) => {
        // Revoke after a delay to allow the download to start
        setTimeout(() => URL.revokeObjectURL(url), 60_000);
        if (chrome.runtime.lastError) {
          sendResponse({ error: chrome.runtime.lastError.message });
        } else {
          sendResponse({ downloadId });
        }
      }
    );
    return true;
  }

  // Download an image/video by URL (uses browser session cookies automatically)
  if (message?.type === 'download') {
    chrome.downloads.download(
      {
        url: message.url,
        filename: message.filename,
        conflictAction: message.conflictAction || 'uniquify',
        saveAs: false,
      },
      (downloadId) => {
        if (chrome.runtime.lastError) {
          sendResponse({ error: chrome.runtime.lastError.message });
        } else {
          sendResponse({ downloadId });
        }
      }
    );
    return true;
  }

  // Open arbitrary HTML in a real tab. Content scripts can't reliably window.open()
  // a blob (popup blocking) — the service worker can always create a tab, so we
  // stash the HTML in storage and open viewer.html which reads + renders it.
  if (message?.type === 'open-html') {
    const key = `viewerHtml:${Date.now()}`;
    chrome.storage.local.set({ [key]: message.html, viewerLatest: key }, () => {
      const url = chrome.runtime.getURL(`viewer.html#${encodeURIComponent(key)}`);
      chrome.tabs.create({ url, active: message.active !== false });
      sendResponse({ ok: true });
    });
    return true;
  }

  // Open (or focus) the live progress window.
  if (message?.type === 'open-progress') {
    const url = chrome.runtime.getURL('progress.html');
    chrome.tabs.query({}, (tabs) => {
      const existing = tabs.find((t) => t.url && t.url.startsWith(url));
      if (existing) {
        chrome.tabs.update(existing.id, { active: true });
        if (existing.windowId != null) chrome.windows.update(existing.windowId, { focused: true });
      } else {
        // A small separate window so it can sit beside the Voice tab.
        chrome.windows.create({ url, type: 'popup', width: 460, height: 620 });
      }
      sendResponse({ ok: true });
    });
    return true;
  }

  if (message?.type === 'open-history') {
    const baseUrl = chrome.runtime.getURL('history.html');

    // Build a URL that carries the current export history in its hash, so the
    // page renders immediately even if it can't read chrome.storage in time.
    // (The page also falls back to chrome.storage.local on its own.)
    const buildUrl = (history, outputFolderName) => {
      try {
        const payload = JSON.stringify({ exportHistory: history || [], outputFolderName: outputFolderName || '' });
        // UTF-8-safe base64
        const b64 = btoa(unescape(encodeURIComponent(payload)));
        return `${baseUrl}#${b64}`;
      } catch (e) {
        return baseUrl; // page will fall back to storage
      }
    };

    chrome.storage.local.get({ exportHistory: [], outputFolderName: '' }, (res) => {
      const url = buildUrl(res.exportHistory, res.outputFolderName);
      chrome.tabs.query({}, (tabs) => {
        const existing = tabs.filter((t) => t.url && t.url.startsWith(baseUrl));
        if (existing.length > 0) {
          // Reuse existing tab — navigate it to the fresh URL (new hash forces a re-render).
          chrome.tabs.update(existing[0].id, { active: true, url });
        } else {
          chrome.tabs.create({ url });
        }
      });
    });

    sendResponse({ ok: true });
    return false;
  }

  return false;
});

// ============================================================
// Logging
// ============================================================
const GVE_PREFIX = '[GV-Exporter]';
const logBuffer = [];
// Single source of truth for the version shown in the panel / progress window.
const EXT_VERSION = (() => {
  try { return chrome.runtime.getManifest().version; } catch (_) { return '?'; }
})();

function log(...args) {
  const msg = args
    .map((a) => (a && typeof a === 'object' ? JSON.stringify(a) : String(a)))
    .join(' ');
  console.log(GVE_PREFIX, ...args);
  logBuffer.push(`${new Date().toISOString().slice(11, 19)} ${msg}`);
  const logEl = document.getElementById('gve-log');
  if (logEl) logEl.textContent = logBuffer.slice(-20).join('\n');
}

function logSnapshot() {
  return [
    `Google Voice Exporter debug log`,
    `Generated: ${new Date().toISOString()}`,
    `URL: ${location.href}`,
    `User agent: ${navigator.userAgent}`,
    '',
    ...logBuffer,
  ].join('\n');
}

// ============================================================
// State
// ============================================================
let stopRequested = false;
let activeExport = null;
let lastExportData = null; // { content, mime } for "open in tab" fallback

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// ============================================================
// Panel UI
// ============================================================
function panel() {
  let node = document.getElementById('gv-exporter-panel');
  if (node) return node;

  node = document.createElement('div');
  node.id = 'gv-exporter-panel';
  node.hidden = true;
  node.innerHTML = `
    <strong>Google Voice Exporter <span style="font-weight:400;opacity:0.5;font-size:10px">v${EXT_VERSION}</span></strong>
    <div id="gve-status">Idle.</div>
    <pre id="gve-log"></pre>
    <div id="gve-buttons">
      <button type="button" id="gve-stop">Stop</button>
      <button type="button" id="gve-progress">Progress window</button>
      <button type="button" id="gve-open-tab">Open in tab</button>
      <button type="button" id="gve-debug-log">Save debug log</button>
      <button type="button" id="gve-dl-images" style="display:none"></button>
    </div>
  `;
  node.querySelector('#gve-stop').addEventListener('click', () => {
    stopRequested = true;
    log('Stop requested via panel');
    setStatus('Stopping after current pass…');
  });
  node.querySelector('#gve-progress').addEventListener('click', () => {
    chrome.runtime.sendMessage({ type: 'open-progress' });
  });
  node.querySelector('#gve-open-tab').addEventListener('click', async () => {
    if (lastExportData) { openInNewTab(lastExportData); return; }
    // Fallback: build the readable view straight from the saved archive, so
    // "Open in tab" works any time — not only right after a fresh export.
    setStatus('Opening saved conversation…');
    const data = await buildViewDataFromArchive();
    if (data) openInNewTab(data);
    else setStatus('Nothing to show yet — run an export first.');
  });
  node.querySelector('#gve-debug-log').addEventListener('click', () => {
    downloadRawText(logSnapshot(), `google-voice-exporter-debug-${new Date().toISOString().replace(/[:.]/g, '-')}.txt`, 'text/plain');
  });
  document.documentElement.appendChild(node);
  return node;
}

function setStatus(message) {
  const node = panel();
  node.hidden = false;
  node.querySelector('#gve-status').textContent = message;
}

// Publish live progress to storage so the separate progress window can show it.
function publishProgress(partial) {
  try {
    chrome.storage.local.get({ exportProgress: {} }, (r) => {
      const prev = r.exportProgress || {};
      const next = { ...prev, ...partial, log: logBuffer.slice(-40), updatedAt: Date.now() };
      chrome.storage.local.set({ exportProgress: next });
    });
  } catch (_) { /* storage may be unavailable; ignore */ }
}

// ============================================================
// Utilities
// ============================================================
function visibleText(node) {
  return (node?.innerText || node?.textContent || '').replace(/\s+/g, ' ').trim();
}

function hashText(value) {
  let hash = 5381;
  for (let i = 0; i < value.length; i++) hash = (hash * 33) ^ value.charCodeAt(i);
  return (hash >>> 0).toString(36);
}

function digitsOnly(str) {
  return str.replace(/\D/g, '');
}

// ============================================================
// Thread phone from URL
// ============================================================
function detectThreadPhone() {
  try {
    const itemId = new URLSearchParams(location.search).get('itemId') || '';
    const digits = digitsOnly(itemId);
    if (digits.length >= 10) {
      const d10 = digits.length === 11 && digits[0] === '1' ? digits.slice(1) : digits.slice(-10);
      const fmt = `(${d10.slice(0, 3)}) ${d10.slice(3, 6)}-${d10.slice(6)}`;
      log('Thread phone from URL:', fmt, 'digits:', d10);
      return { formatted: fmt, digits: d10 };
    }
  } catch (e) {
    log('URL phone parse error:', e.message);
  }
  // Fallback: scan headings
  for (const el of document.querySelectorAll('h1, h2, h3, [role="heading"]')) {
    const phone = parsePhoneFromText(visibleText(el));
    if (phone) {
      log('Thread phone from heading:', phone);
      return { formatted: phone, digits: digitsOnly(phone) };
    }
  }
  log('Thread phone not detected');
  return { formatted: '', digits: '' };
}

// ============================================================
// Locate the thread panel (right-side message area)
// This is essential to avoid confusing sidebar items with messages.
// ============================================================
function getThreadPanel() {
  // Strategy: find the compose textarea first — it's always inside the thread panel.
  // Walk up from it to find the enclosing panel, then look for a CDK viewport within that.
  const compose = document.querySelector(
    'textarea[placeholder], [contenteditable][aria-label*="message" i], textarea[aria-label*="message" i]'
  );

  if (compose) {
    // First try: find a cdk-virtual-scroll-viewport that is an ancestor of (or contains) the compose box
    let el = compose.parentElement;
    for (let i = 0; i < 30 && el && el !== document.body; i++, el = el.parentElement) {
      if (el.tagName.toLowerCase() === 'cdk-virtual-scroll-viewport') {
        log('Thread panel: cdk-virtual-scroll-viewport ancestor of compose, depth', i);
        return el;
      }
    }

    // Second try: find the closest scrollable ancestor with sufficient width (thread column, not sidebar)
    el = compose.parentElement;
    for (let i = 0; i < 30 && el && el !== document.body; i++, el = el.parentElement) {
      const rect = el.getBoundingClientRect();
      const style = getComputedStyle(el);
      const isScrollable = style.overflowY === 'auto' || style.overflowY === 'scroll';
      // Thread panel is typically >500px wide; sidebar is ~280px
      if (isScrollable && rect.width > 500 && rect.height > 400) {
        log('Thread panel: scrollable ancestor of compose at depth', i, el.tagName, el.className.slice(0, 40));
        return el;
      }
    }

    // Third try: walk up to the nearest wide container and search DOWN for cdk viewport
    el = compose.parentElement;
    for (let i = 0; i < 20 && el && el !== document.body; i++, el = el.parentElement) {
      const rect = el.getBoundingClientRect();
      if (rect.width > 500 && rect.height > 400) {
        const vp = el.querySelector('cdk-virtual-scroll-viewport');
        if (vp) {
          log('Thread panel: cdk-virtual-scroll-viewport inside wide ancestor at depth', i);
          return vp;
        }
        log('Thread panel: wide ancestor at depth', i, el.tagName, el.className.slice(0, 40));
        return el;
      }
    }
  }

  // Fallback: pick the widest cdk-virtual-scroll-viewport on the page (not the narrow sidebar)
  const allVps = Array.from(document.querySelectorAll('cdk-virtual-scroll-viewport'));
  if (allVps.length > 0) {
    const widest = allVps.sort((a, b) => b.getBoundingClientRect().width - a.getBoundingClientRect().width)[0];
    log('Thread panel: widest cdk-virtual-scroll-viewport, width:', widest.getBoundingClientRect().width);
    return widest;
  }

  // Google Voice custom elements
  for (const sel of ['gv-thread', 'gv-thread-body', '[data-thread-id]']) {
    const el = document.querySelector(sel);
    if (el) { log('Thread panel:', sel); return el; }
  }

  log('Thread panel not found, using document');
  return null;
}

// ============================================================
// Scroll container — scoped to the thread panel
// ============================================================
function bestScrollContainer(threadPanel) {
  // CDK viewport is itself the scroller
  if (threadPanel && threadPanel.tagName.toLowerCase() === 'cdk-virtual-scroll-viewport') {
    return threadPanel;
  }

  if (threadPanel) {
    // Find the most-scrollable element within the thread panel
    const candidates = [threadPanel, ...Array.from(threadPanel.querySelectorAll('*'))].filter((el) => {
      const overflow = getComputedStyle(el).overflowY;
      return (overflow === 'auto' || overflow === 'scroll') && el.scrollHeight - el.clientHeight > 100;
    });
    if (candidates.length > 0) {
      const best = candidates.sort((a, b) => (b.scrollHeight - b.clientHeight) - (a.scrollHeight - a.clientHeight))[0];
      log('Scroll container in thread panel:', best.tagName, best.className.slice(0, 50));
      return best;
    }
    // Thread panel itself may be scrollable even without overflow style
    if (threadPanel.scrollHeight - threadPanel.clientHeight > 50) {
      log('Thread panel is scroll container:', threadPanel.tagName);
      return threadPanel;
    }
  }

  // Page-level fallback
  const fallbacks = [document.scrollingElement, document.documentElement, document.body];
  const best = fallbacks
    .filter(Boolean)
    .map((el) => ({ el, delta: el.scrollHeight - el.clientHeight }))
    .sort((a, b) => b.delta - a.delta)[0]?.el || document.scrollingElement;
  log('Scroll container fallback:', best.tagName, 'delta:', best.scrollHeight - best.clientHeight);
  return best;
}

// ============================================================
// Timestamp / phone parsing
// ============================================================
function parseTimestampFromText(text) {
  const patterns = [
    /\b(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun),?\s+[A-Z][a-z]{2,8}\s+\d{1,2},?\s+\d{4}[^A-Za-z0-9]{1,4}\d{1,2}:\d{2}\s*(?:AM|PM)?\b/i,
    /\b[A-Z][a-z]{2,8}\s+\d{1,2},?\s+\d{4}[^A-Za-z0-9]{1,4}\d{1,2}:\d{2}\s*(?:AM|PM)?\b/i,
    // Google Voice thread format: "Aug 18, 2025" without time
    /\b[A-Z][a-z]{2,8}\s+\d{1,2},\s+\d{4}\b/i,
    /\b(?:Today|Yesterday),?\s+\d{1,2}:\d{2}\s*(?:AM|PM)?\b/i,
    /\b\d{1,2}\/\d{1,2}\/\d{2,4},?\s+\d{1,2}:\d{2}\s*(?:AM|PM)?\b/i,
  ];
  for (const p of patterns) {
    const m = text.match(p);
    if (m) return m[0];
  }
  return '';
}

function parsePhoneFromText(text) {
  const m = text.match(/(?:\+?1[\s.-]?)?\(?\d{3}\)?[\s.-]\d{3}[\s.-]\d{4}/);
  return m ? m[0] : '';
}

function directionFromElement(element, text) {
  const aria = [
    element.getAttribute('aria-label'),
    element.getAttribute('data-tooltip'),
    element.closest('[aria-label]')?.getAttribute('aria-label'),
  ].filter(Boolean).join(' ');
  const combined = `${aria} ${text}`.toLowerCase();
  if (/\b(outgoing|sent|you:|me:)\b/.test(combined)) return 'outgoing';
  if (/\b(incoming|received|from)\b/.test(combined)) return 'incoming';
  // Positional heuristic: if element is in the right half of the viewport, it's outgoing
  try {
    const rect = element.getBoundingClientRect();
    const mid = window.innerWidth / 2;
    if (rect.left > mid + 50) return 'outgoing';
    if (rect.right < mid - 50) return 'incoming';
  } catch (_) {}
  return '';
}

// ============================================================
// Message element candidates — scoped to thread panel
// ============================================================
function dedupeByAncestry(elements) {
  // Keep only elements not contained by any other element in the set (keep outermost ancestors).
  return elements.filter((el) => !elements.some((other) => other !== el && other.contains(el)));
}

function candidateMessageElements(root) {
  root = root || document;

  // 1. Google Voice custom elements (most reliable if present)
  const gvSel = 'gv-text-message-part, gv-mms-body, [data-message-id], [data-e2e-message-id]';
  const gvEls = Array.from(root.querySelectorAll(gvSel));
  if (gvEls.length > 0) {
    log(`GV custom elements: ${gvEls.length}`);
    return dedupeByAncestry(gvEls);
  }

  // 2. Elements containing Google Voice's "• Aug 18, 2025" thread timestamp pattern
  //    This distinguishes thread messages from sidebar conversation items.
  const threadTimestampRe = /•\s*(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+\d{1,2},\s+\d{4}/i;
  const withGVTimestamp = Array.from(root.querySelectorAll('div, article, li'))
    .filter((el) => {
      const text = visibleText(el);
      return threadTimestampRe.test(text) && text.length >= 4 && text.length <= 3000;
    });
  if (withGVTimestamp.length > 0) {
    log(`Thread-timestamp candidates: ${withGVTimestamp.length}`);
    return dedupeByAncestry(withGVTimestamp);
  }

  // 3. <time> children
  const withTime = Array.from(root.querySelectorAll('div, article, li, [role="listitem"]'))
    .filter((el) => {
      if (!el.querySelector('time')) return false;
      const text = visibleText(el);
      if (text.length < 2 || text.length > 3000) return false;
      if (el.querySelector('textarea, input, button[aria-label*="Send" i]')) return false;
      const rect = el.getBoundingClientRect();
      return rect.width > 40 && rect.height > 12;
    });
  if (withTime.length > 0) {
    log(`Time-child candidates: ${withTime.length}`);
    return dedupeByAncestry(withTime);
  }

  // 4. Last resort: broad sweep of the root (NOT [role="listitem"] from sidebar)
  const broad = Array.from(root.querySelectorAll('div, article'))
    .filter((el) => {
      const text = visibleText(el);
      if (text.length < 4 || text.length > 2000) return false;
      if (el.querySelector('textarea, input, button[aria-label*="Send" i]')) return false;
      const rect = el.getBoundingClientRect();
      return rect.width > 40 && rect.height > 12 && rect.height < 400;
    });
  log(`Broad sweep candidates: ${broad.length}`);
  return dedupeByAncestry(broad);
}

// ============================================================
// Attachment extraction
// ============================================================
// Google Voice serves MMS/attachments from several places:
//   • https://voice.google.com/u/N/a/vi/<hash>-N?m=content   (the common one!)
//   • https://<sub>.googleusercontent.com/...                 (MMS media)
//   • https://usercontent.googleapis.com / storage.googleapis.com
// The old code only accepted googleusercontent/googleapis, so it silently threw
// away every voice.google.com attachment. We now accept all of the above, from
// <img>/<video>/<audio>/<source> AND from <a href> attachment links.
function isAttachmentUrl(url) {
  if (!url) return false;
  if (url.startsWith('data:') || url.startsWith('blob:')) return false;
  // Google Voice attachment endpoints (images, photos, mms, voicemail media).
  if (/^https:\/\/voice\.google\.com\/.*(\/a\/|\/vi\/|[?&]m=content|attachment)/i.test(url)) return true;
  // Google media CDNs.
  if (/^https:\/\/[a-z0-9-]+\.googleusercontent\.com\//i.test(url)) {
    // Exclude account avatars/profile glyphs (…/a/… or …/a-/… or tiny =sNN sizes).
    if (/\/a[-/]/.test(url) || /=s(?:16|24|32|36|40|48)(?:-|$|&)/.test(url)) return false;
    return true;
  }
  if (/^https:\/\/(usercontent\.googleapis\.com|storage\.googleapis\.com)\//i.test(url)) return true;
  return false;
}

function extractAttachmentUrls(element) {
  const urls = [];
  let skippedSmall = 0, skippedHost = 0, skippedData = 0;

  // Media elements.
  for (const node of element.querySelectorAll('img[src], img[currentSrc], video[src], video source[src], audio[src], source[src]')) {
    const url = (node.currentSrc || node.src || '').trim();
    if (!url) continue;
    if (url.startsWith('data:') || url.startsWith('blob:')) { skippedData++; continue; }
    if (node.tagName === 'IMG') {
      const w = node.naturalWidth || node.width || 999;
      const h = node.naturalHeight || node.height || 999;
      // Only reject truly tiny glyphs, and never reject Voice attachment URLs
      // (their intrinsic size can read 0 while still loading).
      if ((w <= 24 || h <= 24) && !/voice\.google\.com/i.test(url)) { skippedSmall++; continue; }
    }
    if (!isAttachmentUrl(url)) { skippedHost++; continue; }
    urls.push(url);
  }

  // Anchor links that point at a Voice attachment (the "?m=content" style).
  for (const a of element.querySelectorAll('a[href]')) {
    const href = (a.href || '').trim();
    if (isAttachmentUrl(href)) urls.push(href);
  }

  // CSS background-image (some thumbnails are rendered this way).
  for (const node of element.querySelectorAll('[style*="background-image"]')) {
    const m = (node.getAttribute('style') || '').match(/url\((['"]?)(https:\/\/[^'")]+)\1\)/i);
    if (m && isAttachmentUrl(m[2])) urls.push(m[2]);
  }

  const unique = [...new Set(urls)];
  if (unique.length > 0 || skippedSmall > 0 || skippedHost > 0) {
    log(`Attachment scan: kept=${unique.length}, skippedTiny=${skippedSmall}, skippedNonAttachment=${skippedHost}, skippedData=${skippedData}`);
    if (unique.length > 0) log('Sample URLs:', unique.slice(0, 3).map((u) => u.slice(0, 100)));
  }
  return unique;
}

// ============================================================
// Core extraction — returns messages found in the DOM right now
// ============================================================
function extractMessages({ root = null, threadPhone = { formatted: '', digits: '' } } = {}) {
  const messagesById = new Map();
  const SKIP = /^(Messages|Calls|Voicemail|Archive|Spam|Settings|Send|Type a message)$/i;

  for (const element of candidateMessageElements(root)) {
    const text = visibleText(element);
    if (!text || text.length < 2 || SKIP.test(text)) continue;

    const timestamp =
      element.querySelector('time')?.getAttribute('datetime') ||
      element.querySelector('time')?.textContent?.trim() ||
      parseTimestampFromText(text);

    const phone = parsePhoneFromText(text) || threadPhone.formatted;
    const direction = directionFromElement(element, text);
    const attachments = extractAttachmentUrls(element);

    // Remove the timestamp from the display text
    const messageText = text.replace(timestamp, '').replace(/\s+/g, ' ').trim();
    if (!messageText && attachments.length === 0) continue;

    const id =
      element.getAttribute('data-message-id') ||
      element.getAttribute('data-e2e-message-id') ||
      hashText([timestamp, direction, phone, messageText, attachments.join('|')].join('||'));

    const candidate = { id, timestamp, direction, phone, text: messageText, attachments, sourceUrl: location.href };
    const existing = messagesById.get(id);
    if (!existing || candidate.text.length > existing.text.length) {
      messagesById.set(id, candidate);
    }
  }

  return Array.from(messagesById.values()).sort((a, b) => {
    const at = Date.parse(a.timestamp), bt = Date.parse(b.timestamp);
    if (Number.isFinite(at) && Number.isFinite(bt)) return at - bt;
    return a.id.localeCompare(b.id);
  });
}

function compactNestedMessages(messages) {
  return messages.filter((msg, i) => {
    if (msg.text.length < 3) return false;
    const nearby = messages.slice(Math.max(0, i - 6), i).concat(messages.slice(i + 1, i + 7));
    return !nearby.some(
      (other) => other.id !== msg.id && other.text.length > msg.text.length + 15 && other.text.includes(msg.text)
    );
  });
}

// ============================================================
// Scroll + accumulate
// Google Voice uses Angular CDK virtual scroll — items not in the
// viewport are removed from the DOM. We must collect at each scroll
// position and merge into an accumulator.
// ============================================================
// opts.stopAtMs: when set ("newer only" mode), stop scrolling up once the oldest
// loaded message is older than this timestamp — we've reached known territory.
async function autoScrollToTop(threadPanel, threadPhone, opts = {}) {
  const scroller = bestScrollContainer(threadPanel);
  const root = threadPanel || document;
  const stopAtMs = opts.stopAtMs ?? null;

  log('Scroller:', scroller.tagName, scroller.id || '', 'scrollHeight:', scroller.scrollHeight, 'clientHeight:', scroller.clientHeight);

  const accumulator = new Map(); // id → message

  function collectVisible() {
    const msgs = extractMessages({ root, threadPhone });
    let added = 0;
    for (const m of msgs) {
      if (!accumulator.has(m.id)) { accumulator.set(m.id, m); added++; }
      else {
        const ex = accumulator.get(m.id);
        if (m.text.length > ex.text.length || m.attachments.length > ex.attachments.length) {
          accumulator.set(m.id, m);
        }
      }
    }
    return added;
  }

  // Oldest parseable timestamp currently accumulated (epoch ms) or null.
  function oldestLoadedMs() {
    let oldest = null;
    for (const m of accumulator.values()) {
      const t = msgTime(m);
      if (t == null) continue;
      if (oldest == null || t < oldest) oldest = t;
    }
    return oldest;
  }

  // Wait until either new content renders or maxWait elapses — instead of a flat
  // 1s sleep. Polls cheaply and returns as soon as the message count grows.
  async function waitForContent(maxWait = 1400, poll = 90) {
    const start = Date.now();
    const before = accumulator.size;
    while (Date.now() - start < maxWait) {
      await sleep(poll);
      if (collectVisible() > 0 && accumulator.size > before) return true;
    }
    return false;
  }

  collectVisible();
  log(`Initial collection: ${accumulator.size} messages`);

  // Scroll to bottom first so we capture the most recent messages, then work up.
  scroller.scrollTop = scroller.scrollHeight;
  scroller.dispatchEvent(new Event('scroll', { bubbles: true }));
  await waitForContent(1500);
  collectVisible();

  let stablePasses = 0;
  let lastSize = accumulator.size;
  let lastScrollTop = scroller.scrollTop;
  let pass = 0;
  // MAX THOROUGHNESS: long (year+) threads make Google's lazy loader pause
  // intermittently. We must NOT treat a pause as "reached the top". So we use a
  // high stable-pass threshold, escalating waits, and hard "jump to very top"
  // nudges before we ever conclude we're done.
  const STABLE_LIMIT = 20;     // was 6 — tolerate long loader pauses
  const MAX_PASSES = 4000;     // was 800 — enough for very long threads
  const pageJump = () => Math.max(700, Math.floor(scroller.clientHeight * 0.9));

  // Try hard to wake up a stalled loader: jump to the absolute top, fire wheel +
  // Home key + scroll, and wait longer. Returns true if new messages appeared.
  async function hardNudge() {
    const before = accumulator.size;
    scroller.scrollTop = 0;
    scroller.dispatchEvent(new Event('scroll', { bubbles: true }));
    scroller.dispatchEvent(new WheelEvent('wheel', { deltaY: -3000, bubbles: true, cancelable: true }));
    scroller.dispatchEvent(new KeyboardEvent('keydown', { key: 'Home', bubbles: true }));
    window.dispatchEvent(new Event('scroll'));
    await waitForContent(3500, 120);
    // Nudge back down a touch then up again — sometimes forces a fetch.
    scroller.scrollTop = Math.min(scroller.scrollHeight, scroller.clientHeight);
    await sleep(400);
    scroller.scrollTop = 0;
    scroller.dispatchEvent(new Event('scroll', { bubbles: true }));
    await waitForContent(3500, 120);
    collectVisible();
    return accumulator.size > before;
  }

  while (!stopRequested && stablePasses < STABLE_LIMIT && pass < MAX_PASSES) {
    pass++;

    const currentTop = scroller.scrollTop;
    const CHUNK = pageJump();
    scroller.scrollTop = Math.max(0, currentTop - CHUNK);

    scroller.dispatchEvent(new Event('scroll', { bubbles: true }));
    scroller.dispatchEvent(new WheelEvent('wheel', { deltaY: -(CHUNK), bubbles: true, cancelable: true }));
    window.dispatchEvent(new Event('scroll'));

    // Advance as soon as new messages render; escalate the wait as we get stuck so
    // a slow loader gets more time before we count the pass as "stable".
    const waitMs = 1400 + Math.min(stablePasses, 10) * 600; // up to ~7.4s when stalling
    await waitForContent(waitMs);

    let added = collectVisible();
    let total = accumulator.size;

    const atTop = scroller.scrollTop <= 2;
    let grew = total > lastSize;
    const moved = Math.abs(scroller.scrollTop - lastScrollTop) > 2;

    // If we appear stuck at the top with no growth, don't give up yet — hard-nudge.
    if (!grew && atTop) {
      const woke = await hardNudge();
      added = collectVisible();
      total = accumulator.size;
      grew = total > lastSize;
      if (woke) log(`Hard nudge woke the loader: +${total - lastSize} messages`);
    }

    if (!grew && (atTop || !moved)) stablePasses++;
    else stablePasses = 0;

    lastSize = total;
    lastScrollTop = scroller.scrollTop;

    const oldest = oldestLoadedMs();
    const newest = (() => { let n = null; for (const m of accumulator.values()) { const t = msgTime(m); if (t != null && (n == null || t > n)) n = t; } return n; })();
    const rangeLabel = oldest != null ? `${fmtDate(oldest)} → ${fmtDate(newest)}` : 'dates loading…';

    setStatus(`Scrolling… ${total} msgs · ${rangeLabel} · stable ${stablePasses}/${STABLE_LIMIT}`);
    log(`Pass ${pass}: top=${currentTop}→${scroller.scrollTop}, added=${added}, total=${total}, oldest=${fmtDate(oldest)}, stable=${stablePasses}`);
    publishProgress({ phase: 'scrolling', status: `Scrolling… ${rangeLabel}`, pass, total, stable: stablePasses, earliest: oldest, latest: newest });

    // "Newer only" early stop: we've scrolled back into already-archived dates.
    if (stopAtMs != null && oldest != null && oldest <= stopAtMs) {
      log(`Reached archived range (oldest ${fmtDate(oldest)} ≤ ${fmtDate(stopAtMs)}). Stopping early.`);
      setStatus(`Reached already-saved messages (${fmtDate(stopAtMs)}). Stopping.`);
      break;
    }

    if (pass % 8 === 0) await saveCheckpoint(getSortedAccumulator(accumulator));
  }

  log(`Scroll done: ${pass} passes, ${accumulator.size} messages accumulated`);
  publishProgress({ phase: 'scrolling', status: `Scroll complete — ${accumulator.size} messages`, pass, total: accumulator.size, stable: 6 });
  return getSortedAccumulator(accumulator);
}

function getSortedAccumulator(accumulator) {
  return Array.from(accumulator.values()).sort((a, b) => {
    const at = Date.parse(a.timestamp), bt = Date.parse(b.timestamp);
    if (Number.isFinite(at) && Number.isFinite(bt)) return at - bt;
    return a.id.localeCompare(b.id);
  });
}

// ============================================================
// Checkpoint
// ============================================================
function checkpointKey() {
  const itemId = new URLSearchParams(location.search).get('itemId') || location.pathname;
  return `checkpoint:${itemId}`;
}

async function saveCheckpoint(messages) {
  try {
    await chrome.storage.local.set({
      [checkpointKey()]: { messages, count: messages.length, savedAt: new Date().toISOString(), sourceUrl: location.href },
    });
    log(`Checkpoint saved: ${messages.length} messages`);
  } catch (e) {
    log('Checkpoint save failed:', e.message);
  }
}

async function loadCheckpoint() {
  try {
    const data = await chrome.storage.local.get({ [checkpointKey()]: null });
    return data[checkpointKey()];
  } catch (e) {
    log('Checkpoint load failed:', e.message);
    return null;
  }
}

async function clearCheckpoint() {
  try {
    await chrome.storage.local.remove(checkpointKey());
  } catch (e) {
    log('Checkpoint clear failed:', e.message);
  }
}

// ============================================================
// Per-contact archive (the growing, deduped history for a number)
// Keyed by the thread's 10-digit number. Stores every message we've
// ever captured for that contact plus the covered date range.
// ============================================================
function archiveKey(threadPhone) {
  const digits = (threadPhone?.digits || '').slice(-10) || 'unknown';
  return `archive:${digits}`;
}

// Best-effort parse of a message timestamp into epoch ms. Returns null if unknown.
function msgTime(m) {
  if (!m || !m.timestamp) return null;
  const t = Date.parse(m.timestamp);
  return Number.isFinite(t) ? t : null;
}

// Compute {earliest, latest} epoch ms over a message list (ignores unparseable).
function dateRange(messages) {
  let earliest = null, latest = null;
  for (const m of messages) {
    const t = msgTime(m);
    if (t == null) continue;
    if (earliest == null || t < earliest) earliest = t;
    if (latest == null || t > latest) latest = t;
  }
  return { earliest, latest };
}

function fmtDate(ms) {
  if (ms == null) return 'unknown';
  return new Date(ms).toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
}

async function loadArchive(threadPhone) {
  try {
    const key = archiveKey(threadPhone);
    const data = await chrome.storage.local.get({ [key]: null });
    return data[key]; // { messages, earliest, latest, count, updatedAt } | null
  } catch (e) {
    log('Archive load failed:', e.message);
    return null;
  }
}

// Merge new messages into the existing archive, dedupe by id, recompute range.
async function mergeIntoArchive(threadPhone, newMessages) {
  const key = archiveKey(threadPhone);
  const existing = await loadArchive(threadPhone);
  const map = new Map((existing?.messages || []).map((m) => [m.id, m]));
  let added = 0;
  for (const m of newMessages) {
    const prev = map.get(m.id);
    if (!prev) { map.set(m.id, m); added++; }
    else if ((m.text || '').length > (prev.text || '').length ||
             (m.attachments || []).length > (prev.attachments || []).length) {
      map.set(m.id, m); // richer copy wins
    }
  }
  const merged = getSortedAccumulator(map);
  const range = dateRange(merged);
  const archive = {
    messages: merged,
    count: merged.length,
    earliest: range.earliest,
    latest: range.latest,
    updatedAt: new Date().toISOString(),
  };
  try {
    await chrome.storage.local.set({ [key]: archive });
    log(`Archive merged: +${added} new, ${merged.length} total, range ${fmtDate(range.earliest)} → ${fmtDate(range.latest)}`);
  } catch (e) {
    // Archives can exceed chrome.storage quota for huge threads; warn but don't crash.
    log('Archive save failed (thread may be too large for storage):', e.message);
  }
  return { archive, added };
}

// ============================================================
// Filtering
// ============================================================
async function applyFilters(messages, options) {
  let filtered = messages;

  if (options.filter) {
    const needle = options.filter.toLowerCase().trim();
    const needleDigits = digitsOnly(needle);
    filtered = filtered.filter((msg) => {
      const haystack = [msg.phone, msg.text, msg.direction, msg.timestamp].join(' ').toLowerCase();
      if (haystack.includes(needle)) return true;
      if (needleDigits.length >= 7 && digitsOnly(haystack).includes(needleDigits)) return true;
      return false;
    });
    log(`Filter "${options.filter}": ${messages.length} → ${filtered.length}`);
    if (filtered.length === 0) {
      log('Sample phones:', messages.slice(0, 5).map((m) => `"${m.phone}"`).join(', '));
    }
  }

  if (options.diffOnly) {
    const key = `lastExport:${location.pathname}:${options.filter || 'all'}`;
    const stored = await chrome.storage.local.get({ [key]: '' });
    const lastId = stored[key];
    const lastIndex = filtered.findIndex((m) => m.id === lastId);
    if (lastIndex >= 0) filtered = filtered.slice(lastIndex + 1);
    if (messages.length > 0) await chrome.storage.local.set({ [key]: messages[messages.length - 1].id });
    log(`diffOnly: ${filtered.length} new`);
  }

  return filtered;
}

// ============================================================
// Serialization
// ============================================================
function csvEscape(value) {
  const text = Array.isArray(value) ? value.join(' ') : String(value ?? '');
  return /[",\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
}

function serialize(messages, format) {
  if (format === 'csv') {
    const rows = [['id', 'timestamp', 'direction', 'phone', 'text', 'attachments', 'sourceUrl']].concat(
      messages.map((m) => [m.id, m.timestamp, m.direction, m.phone, m.text, m.attachments.join(' '), m.sourceUrl])
    );
    return rows.map((row) => row.map(csvEscape).join(',')).join('\n');
  }
  if (format === 'txt') {
    return messages.map((m) => {
      const heading = [m.timestamp, m.direction, m.phone].filter(Boolean).join(' | ');
      const imgs = m.attachments.length ? `\nImages:\n  ${m.attachments.join('\n  ')}` : '';
      return `${heading}\n${m.text}${imgs}`.trim();
    }).join('\n\n---\n\n');
  }
  return JSON.stringify({ exportedAt: new Date().toISOString(), sourceUrl: location.href, count: messages.length, messages }, null, 2);
}

function makeFilename(format) {
  return `google-voice-thread-${new Date().toISOString().replace(/[:.]/g, '-')}.${format}`;
}

// ============================================================
// File System Access API — output folder persistence via IndexedDB
// ============================================================
const FS_IDB = 'gve-filestore';
const FS_STORE = 'handles';
const FS_KEY = 'outputDir';

function fsOpenDB() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(FS_IDB, 1);
    req.onupgradeneeded = (e) => e.target.result.createObjectStore(FS_STORE);
    req.onsuccess = (e) => resolve(e.target.result);
    req.onerror = (e) => reject(e.target.error);
  });
}

async function fsSaveHandle(handle) {
  const db = await fsOpenDB();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(FS_STORE, 'readwrite');
    tx.objectStore(FS_STORE).put(handle, FS_KEY);
    tx.oncomplete = resolve;
    tx.onerror = () => reject(tx.error);
  });
}

async function fsGetHandle() {
  const db = await fsOpenDB();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(FS_STORE, 'readonly');
    const req = tx.objectStore(FS_STORE).get(FS_KEY);
    req.onsuccess = () => resolve(req.result ?? null);
    req.onerror = () => reject(req.error);
  });
}

async function fsGetVerifiedHandle() {
  const handle = await fsGetHandle();
  if (!handle) return null;
  try {
    const perm = await handle.queryPermission({ mode: 'readwrite' });
    if (perm === 'granted') return handle;
    const req = await handle.requestPermission({ mode: 'readwrite' });
    return req === 'granted' ? handle : null;
  } catch {
    return null;
  }
}

// Must be called from a user gesture context (the export button click propagates through).
async function fsRequireFolder(force = false) {
  if (!force) {
    const existing = await fsGetVerifiedHandle();
    if (existing) return existing;
  }
  setStatus('📁 Pick your export folder (e.g. Documents/root/google-voice-exports-storage)…');
  const handle = await window.showDirectoryPicker({ id: 'gve-output', mode: 'readwrite', startIn: 'documents' });
  await fsSaveHandle(handle);
  log('Output folder set:', handle.name);
  return handle;
}

async function fsWriteTextFile(dirHandle, subpath, content, mime) {
  const parts = subpath.split('/').filter(Boolean);
  let cur = dirHandle;
  for (const part of parts.slice(0, -1)) cur = await cur.getDirectoryHandle(part, { create: true });
  const fh = await cur.getFileHandle(parts.at(-1), { create: true });
  const w = await fh.createWritable();
  await w.write(new Blob([content], { type: `${mime};charset=utf-8` }));
  await w.close();
}

// Pick a sensible file extension from the HTTP content-type (Voice attachment
// URLs carry no extension), falling back to any extension in the URL, then jpg.
function pickExt(contentType, url, blobType) {
  const ct = (contentType || blobType || '').toLowerCase();
  const map = {
    'image/jpeg': 'jpg', 'image/jpg': 'jpg', 'image/png': 'png', 'image/gif': 'gif',
    'image/webp': 'webp', 'image/heic': 'heic', 'image/heif': 'heif', 'image/bmp': 'bmp',
    'video/mp4': 'mp4', 'video/quicktime': 'mov', 'video/3gpp': '3gp', 'video/webm': 'webm',
    'audio/mpeg': 'mp3', 'audio/amr': 'amr', 'audio/ogg': 'ogg',
    'application/pdf': 'pdf',
  };
  for (const k in map) if (ct.includes(k)) return map[k];
  const m = (url || '').match(/\.(jpe?g|png|gif|webp|heic|heif|bmp|mp4|mov|3gp|webm|mp3|amr|ogg|pdf)(\?|$)/i);
  if (m) return m[1].toLowerCase().replace('jpeg', 'jpg');
  return 'jpg';
}

// Write <dir>/images/<phoneSlug>/<baseName>.<ext>. Returns the final filename.
async function fsWriteImageFile(dirHandle, phoneSlug, baseName, url) {
  const resp = await fetch(url, { credentials: 'include' });
  if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
  const blob = await resp.blob();
  if (blob.size === 0) throw new Error('empty response (0 bytes)');
  const ext = pickExt(resp.headers.get('content-type'), url, blob.type);
  const filename = `${baseName}.${ext}`;
  const imagesDir = await dirHandle.getDirectoryHandle('images', { create: true });
  const phoneDir = await imagesDir.getDirectoryHandle(phoneSlug || 'unknown', { create: true });
  const fh = await phoneDir.getFileHandle(filename, { create: true });
  const w = await fh.createWritable();
  await w.write(blob);
  await w.close();
  return filename;
}

// Is there already a non-empty file named <baseName>.<anything> in the folder?
// (We don't know the extension ahead of time, so match by base name.)
async function fsImageBaseExists(dirHandle, phoneSlug, baseName) {
  try {
    const imagesDir = await dirHandle.getDirectoryHandle('images');
    const phoneDir = await imagesDir.getDirectoryHandle(phoneSlug || 'unknown');
    for await (const [name, handle] of phoneDir.entries()) {
      if (handle.kind === 'file' && name.startsWith(baseName + '.')) {
        const f = await handle.getFile();
        if (f.size > 0) return true;
      }
    }
    return false;
  } catch {
    return false;
  }
}

// ============================================================
// Download + new-tab fallback (debug log only)
// ============================================================
function downloadRawText(content, fname, mime) {
  try {
    const blob = new Blob([content], { type: `${mime};charset=utf-8` });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = fname;
    link.style.display = 'none';
    document.documentElement.appendChild(link);
    link.click();
    link.remove();
    setTimeout(() => URL.revokeObjectURL(url), 120_000);
    log(`Debug log download triggered: ${fname}`);
  } catch (e) {
    log('Raw text download failed:', e.message);
  }
}

function escapeHtml(s) {
  return String(s ?? '')
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

// Build a readable chat-style HTML page from exported messages.
function buildChatHtml(data) {
  const messages = Array.isArray(data.messages) ? data.messages : [];
  const folder = data.folderName || 'your export folder';
  const filePath = `${folder}/${data.fileName || ''}`;
  const imagesPath = data.imageSubfolder ? `${folder}/${data.imageSubfolder}` : null;
  const title = data.phone ? `Conversation with ${data.phone}` : 'Google Voice conversation';
  const cov = dateRange(messages);
  const coverageText = cov.earliest != null ? `${fmtDate(cov.earliest)} → ${fmtDate(cov.latest)}` : 'dates unavailable';

  const bubbles = messages.map((m) => {
    const outgoing = m.direction === 'outgoing';
    const side = outgoing ? 'out' : 'in';
    const imgs = (m.attachments || []).map((u) =>
      `<a href="${escapeHtml(u)}" target="_blank" rel="noopener"><img class="att" src="${escapeHtml(u)}" loading="lazy" alt="attachment" onerror="this.replaceWith(Object.assign(document.createElement('a'),{href:this.src,target:'_blank',textContent:'🖼 image (open)',className:'att-link'}))"></a>`
    ).join('');
    const text = m.text ? `<div class="text">${escapeHtml(m.text)}</div>` : '';
    const meta = `<div class="meta">${escapeHtml(m.timestamp || '')}${m.phone ? ' · ' + escapeHtml(m.phone) : ''}</div>`;
    return `<div class="row ${side}"><div class="bubble">${text}${imgs}${meta}</div></div>`;
  }).join('\n');

  const locationBanner = `
    <div class="locbar">
      <div class="loc-row">
        <span class="loc-label">📄 Export file</span>
        <code class="loc-path" id="p-file">${escapeHtml(filePath)}</code>
        <button class="copy" data-target="p-file">Copy path</button>
      </div>
      ${imagesPath ? `
      <div class="loc-row">
        <span class="loc-label">🖼 Images folder</span>
        <code class="loc-path" id="p-img">${escapeHtml(imagesPath)}</code>
        <button class="copy" data-target="p-img">Copy path</button>
      </div>` : `<div class="loc-row"><span class="loc-note">No image attachments in this export.</span></div>`}
      <div class="loc-hint">Saved inside the folder you picked. Browsers can't open a local folder from a link, so use “Copy path” and paste it into Finder (⌘⇧G) or your file manager.</div>
    </div>`;

  return `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(title)}</title>
<style>
  :root{--bg:#0f1117;--surface:#1a1d27;--in:#22263a;--out:#1d4ed8;--text:#e2e8f0;--dim:#94a3b8;--border:rgba(255,255,255,.08);}
  *{box-sizing:border-box;margin:0;padding:0;}
  body{background:var(--bg);color:var(--text);font:15px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif;}
  header{position:sticky;top:0;z-index:5;background:rgba(15,17,23,.96);backdrop-filter:blur(6px);border-bottom:1px solid var(--border);padding:16px 20px;}
  header h1{font-size:18px;font-weight:700;}
  header .sub{color:var(--dim);font-size:13px;margin-top:2px;}
  .locbar{max-width:820px;margin:14px auto 0;background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:14px 16px;}
  .loc-row{display:flex;align-items:center;gap:10px;flex-wrap:wrap;margin-bottom:8px;}
  .loc-label{font-size:12px;color:var(--dim);min-width:104px;font-weight:600;}
  .loc-path{flex:1;min-width:200px;background:#0d0f14;border:1px solid var(--border);border-radius:6px;padding:6px 9px;font:12px/1.4 "SF Mono","Fira Mono",monospace;color:#7eb3ff;word-break:break-all;}
  .loc-note{color:var(--dim);font-size:13px;}
  .copy{background:var(--out);border:0;color:#fff;border-radius:6px;padding:6px 11px;font-size:12px;font-weight:600;cursor:pointer;}
  .copy:hover{background:#2563eb;}
  .loc-hint{color:var(--dim);font-size:11.5px;margin-top:6px;}
  main{max-width:820px;margin:0 auto;padding:20px 16px 64px;display:flex;flex-direction:column;gap:8px;}
  .row{display:flex;}
  .row.out{justify-content:flex-end;}
  .row.in{justify-content:flex-start;}
  .bubble{max-width:74%;padding:9px 13px;border-radius:16px;border:1px solid var(--border);}
  .row.in .bubble{background:var(--in);border-bottom-left-radius:5px;}
  .row.out .bubble{background:var(--out);border-bottom-right-radius:5px;}
  .text{white-space:pre-wrap;word-break:break-word;}
  .att{max-width:260px;max-height:300px;border-radius:10px;margin-top:6px;display:block;}
  .att-link{display:inline-block;margin-top:6px;color:#bfdbfe;font-size:13px;}
  .meta{font-size:11px;color:var(--dim);margin-top:5px;opacity:.85;}
  .row.out .meta{color:#cfe0ff;}
  .count{text-align:center;color:var(--dim);font-size:12px;margin:6px 0 2px;}
</style></head>
<body>
  <header>
    <h1>${escapeHtml(title)}</h1>
    <div class="sub">${messages.length} message${messages.length !== 1 ? 's' : ''} · 📅 ${escapeHtml(coverageText)} · Google Voice Exporter v${escapeHtml(EXT_VERSION)}</div>
    ${locationBanner}
  </header>
  <main>
    ${bubbles || '<div class="count">No messages to display.</div>'}
  </main>
  <script>
    document.querySelectorAll('.copy').forEach(function(b){
      b.addEventListener('click', function(){
        var t=document.getElementById(b.dataset.target);
        navigator.clipboard.writeText(t.textContent).then(function(){
          var o=b.textContent; b.textContent='Copied ✓';
          setTimeout(function(){ b.textContent=o; }, 1500);
        });
      });
    });
  <\/script>
</body></html>`;
}

function openInNewTab(data) {
  try {
    // Legacy callers may still pass (content, mime); normalize.
    if (typeof data === 'string') data = { content: data, mime: arguments[1] || 'text/plain' };

    let html, mime = 'text/html';
    if (Array.isArray(data.messages) && data.messages.length >= 0 && data.fileName !== undefined) {
      html = buildChatHtml(data);
    } else {
      // No structured messages available — fall back to showing the raw content.
      html = `<!doctype html><meta charset="utf-8"><title>Export</title>
        <body style="background:#0f1117;color:#e2e8f0;font:13px/1.5 monospace;padding:16px">
        <pre style="white-space:pre-wrap;word-break:break-word">${escapeHtml(data.content || '')}</pre></body>`;
    }

    // Route through the background worker — content-script window.open() of a blob
    // is frequently popup-blocked (that was the "nothing happens"/blank-tab bug).
    chrome.runtime.sendMessage({ type: 'open-html', html, active: true }, (resp) => {
      if (chrome.runtime.lastError || !resp?.ok) {
        // Fallback: try a direct blob tab if messaging failed.
        try {
          const url = URL.createObjectURL(new Blob([html], { type: 'text/html;charset=utf-8' }));
          window.open(url, '_blank');
          setTimeout(() => URL.revokeObjectURL(url), 600_000);
        } catch (e2) {
          setStatus('Open in tab failed: ' + (chrome.runtime.lastError?.message || e2.message));
        }
      } else {
        log('Opened readable view in new tab (via background)');
      }
    });
  } catch (e) {
    log('Open-in-tab failed:', e.message);
    setStatus('Open in tab failed: ' + e.message);
  }
}

async function downloadFile(dirHandle, messages, format, threadPhone) {
  const content = serialize(messages, format);
  const mime = format === 'json' ? 'application/json' : format === 'csv' ? 'text/csv' : 'text/plain';
  const fname = makeFilename(format);
  const phoneSlug = (threadPhone?.digits || 'unknown').slice(-10);
  const hasImages = messages.some((m) => m.attachments && m.attachments.length > 0);
  // Keep the structured data + locations so "Open in tab" can render a readable view.
  lastExportData = {
    content,
    mime,
    messages,
    folderName: dirHandle.name,
    fileName: fname,
    phone: threadPhone?.formatted || '',
    imageSubfolder: hasImages ? `images/${phoneSlug}` : null,
  };
  log(`Writing: ${fname} (${content.length} bytes, ${messages.length} messages)`);
  await fsWriteTextFile(dirHandle, fname, content, mime);
  log('File written:', fname);
  return { fname };
}

// ============================================================
// Image downloading (Phase 2)
// ============================================================
async function downloadImages(dirHandle, messages, threadPhone, opts = {}) {
  const skipExisting = opts.skipExisting === true;
  const urls = [...new Set(messages.flatMap((m) => m.attachments).filter(Boolean))];
  if (urls.length === 0) { setStatus('No images found.'); return { done: 0, failed: 0, skipped: 0, total: 0 }; }
  log(`Downloading ${urls.length} images via File System Access API${skipExisting ? ' (skip existing)' : ''}`);
  const phoneSlug = (threadPhone?.digits || 'unknown').slice(-10);
  let done = 0, failed = 0, skipped = 0;
  const failures = [];
  for (const url of urls) {
    if (stopRequested) break;
    const base = `gv-img-${hashText(url)}`;
    // Retry each attachment a couple of times — Voice CDN occasionally 302/500s.
    let ok = false, lastErr = null;
    try {
      if (skipExisting && await fsImageBaseExists(dirHandle, phoneSlug, base)) {
        skipped++;
        setStatus(`Syncing images… ${done} new, ${skipped} already saved / ${urls.length}`);
        continue; // already on disk — no re-fetch
      }
    } catch (_) { /* fall through to download */ }

    for (let attempt = 1; attempt <= 3 && !ok && !stopRequested; attempt++) {
      try {
        const savedName = await fsWriteImageFile(dirHandle, phoneSlug, base, url);
        ok = true;
        done++;
        setStatus(`Downloading images… ${done} new${skipped ? `, ${skipped} skipped` : ''} / ${urls.length}`);
        log(`Saved ${savedName}`);
      } catch (e) {
        lastErr = e;
        await sleep(400 * attempt); // backoff before retry
      }
    }
    if (!ok) {
      failed++;
      failures.push(url);
      log(`Image FAILED after retries (${url.slice(0, 90)}): ${lastErr && lastErr.message}`);
    }
    await sleep(250);
  }
  const s = `Images: ${done} downloaded${skipped ? `, ${skipped} already present` : ''}, ${failed} failed of ${urls.length}.`;
  setStatus(s); log(s);
  if (failures.length) log('Failed URLs (first 5):', failures.slice(0, 5));
  return { done, failed, skipped, total: urls.length, failures };
}

// Re-sync: pull any MISSING images for this contact from the saved archive,
// without re-scrolling the thread. Fast — only fetches what isn't on disk.
async function resyncImages() {
  const threadPhone = detectThreadPhone();
  const archive = await loadArchive(threadPhone);
  if (!archive || !(archive.messages && archive.messages.length)) {
    setStatus('No saved archive for this contact yet — run an export first.');
    return { message: 'Nothing to sync — no saved archive for this contact.' };
  }
  let dirHandle;
  try {
    dirHandle = await fsRequireFolder(false);
  } catch (e) {
    setStatus('Re-sync cancelled — no output folder.');
    return { message: 'No output folder selected.' };
  }
  const total = [...new Set(archive.messages.flatMap((m) => m.attachments || []).filter(Boolean))].length;
  if (total === 0) { setStatus('This contact has no image attachments.'); return { message: 'No images in this thread.' }; }

  stopRequested = false;
  chrome.runtime.sendMessage({ type: 'open-progress' });
  publishProgress({ phase: 'images', status: `Re-syncing images (${total} total)…`, total: archive.count, earliest: archive.earliest, latest: archive.latest });
  setStatus(`Re-syncing images — checking ${total} for anything missing…`);

  const r = await downloadImages(dirHandle, archive.messages, threadPhone, { skipExisting: true });
  const msg = `Re-sync done: ${r.done} newly downloaded, ${r.skipped} already saved, ${r.failed} failed (of ${r.total}).`;
  publishProgress({ phase: 'done', status: msg, total: archive.count, earliest: archive.earliest, latest: archive.latest });
  setStatus(msg);
  // Open the history tab so there's a clear landing/confirmation after a re-sync.
  chrome.runtime.sendMessage({ type: 'open-history' });
  return { message: msg, ...r };
}

// Build the "readable view" payload from the saved archive for the open thread,
// so "Open in tab" works any time (not just right after an export).
async function buildViewDataFromArchive() {
  const tp = detectThreadPhone();
  const archive = await loadArchive(tp);
  if (!archive || !(archive.messages && archive.messages.length)) return null;
  const phoneSlug = (tp.digits || 'unknown').slice(-10);
  const hasImages = archive.messages.some((m) => m.attachments && m.attachments.length);
  let folderName = 'your export folder';
  try {
    const s = await new Promise((r) => chrome.storage.local.get({ outputFolderName: '' }, r));
    if (s.outputFolderName) folderName = s.outputFolderName;
  } catch (_) {}
  return {
    messages: archive.messages,
    folderName,
    fileName: '(latest saved archive)',
    phone: tp.formatted || '',
    imageSubfolder: hasImages ? `images/${phoneSlug}` : null,
  };
}

// ============================================================
// Main export
// ============================================================
async function startExport(options) {
  if (activeExport) { log('Already running'); return activeExport; }
  stopRequested = false;
  log('--- Export start ---', JSON.stringify(options));

  const threadPhone = detectThreadPhone();
  log('Thread phone:', JSON.stringify(threadPhone));

  // Acquire output folder — must happen before the async IIFE so it's
  // triggered directly from the user-gesture call stack (required by browser).
  let dirHandle;
  try {
    dirHandle = await fsRequireFolder(options.changeFolder === true);
  } catch (e) {
    log('Folder picker cancelled or failed:', e.message);
    setStatus('Export cancelled — no output folder selected.');
    return { message: 'No output folder selected.' };
  }
  // Store folder name in chrome.storage so history.html and popup can display it.
  chrome.storage.local.set({ outputFolderName: dirHandle.name });
  log('Output folder:', dirHandle.name);
  setStatus(`📁 Output folder: ${dirHandle.name}`);

  // dryRun = just set the folder, don't export
  if (options.dryRun) {
    return { message: `Output folder set to: ${dirHandle.name}` };
  }

  // Reset progress and open the live progress window so the user can watch
  // without keeping focus on the panel (the Voice tab must stay visible though).
  publishProgress({ phase: 'starting', status: 'Starting export…', pass: 0, total: 0, stable: 0 });
  chrome.runtime.sendMessage({ type: 'open-progress' });

  activeExport = (async () => {
    const checkpoint = await loadCheckpoint();
    if (checkpoint) log(`Checkpoint: ${checkpoint.count} msgs from ${checkpoint.savedAt}`);

    // What do we already have archived for this contact?
    const priorArchive = await loadArchive(threadPhone);
    // mode: 'full' (scrape everything), 'newer' (stop at archived range), 'earlier' (keep going past it)
    let mode = options.mode || (priorArchive && priorArchive.count > 0 ? 'newer' : 'full');
    if (priorArchive && priorArchive.count > 0) {
      const cov = `${priorArchive.count} msgs already saved, covering ${fmtDate(priorArchive.earliest)} → ${fmtDate(priorArchive.latest)}`;
      log('Archive found:', cov, '| mode:', mode);
      setStatus(`📚 ${cov}. ${mode === 'newer' ? 'Fetching newer…' : mode === 'earlier' ? 'Fetching earlier…' : 'Re-scanning all…'}`);
      publishProgress({ phase: 'starting', status: cov, archiveCount: priorArchive.count, archiveEarliest: priorArchive.earliest, archiveLatest: priorArchive.latest, mode });
    } else {
      log('No prior archive — full first-run capture.');
      setStatus('First run — capturing the whole history (most recent first)…');
    }

    let allMessages;

    if (options.resume && checkpoint?.messages?.length > 0) {
      log('Resuming from checkpoint, skipping scroll');
      setStatus(`Resuming from ${checkpoint.count} saved messages…`);
      allMessages = checkpoint.messages;
    } else {
      setStatus('Finding thread panel…');
      const threadPanel = getThreadPanel();
      log('Thread panel found:', threadPanel ? threadPanel.tagName : 'none');

      // In 'newer' mode, stop scrolling once we reach the latest already-archived
      // message (no point re-scrolling old territory). 'full'/'earlier' load all.
      const stopAtMs = (mode === 'newer' && priorArchive?.latest != null) ? priorArchive.latest : null;
      setStatus(mode === 'newer' ? 'Loading newer messages…' : 'Scrolling to load full history…');
      allMessages = await autoScrollToTop(threadPanel, threadPhone, { stopAtMs });

      // Merge with any existing checkpoint so a stopped run isn't fully lost
      if (checkpoint?.messages?.length > 0) {
        const merged = new Map(checkpoint.messages.map((m) => [m.id, m]));
        for (const m of allMessages) merged.set(m.id, m);
        allMessages = getSortedAccumulator(merged);
        log(`Merged with checkpoint: ${allMessages.length} total`);
      }
    }

    // If the user stopped, DON'T discard — save whatever we collected so far.
    // Only bail out entirely if nothing was gathered at all.
    if (stopRequested) {
      if (!allMessages || allMessages.length === 0) {
        setStatus('Stopped — nothing collected yet.');
        publishProgress({ phase: 'stopped', status: 'Stopped — nothing collected.' });
        return { message: 'Stopped (nothing to save).' };
      }
      log(`Stopped by user — saving ${allMessages.length} collected messages.`);
      setStatus(`Stopped — saving ${allMessages.length} messages…`);
      publishProgress({ phase: 'stopped', status: `Stopped — saving ${allMessages.length} messages…`, total: allMessages.length });
    }

    allMessages = compactNestedMessages(allMessages);
    log(`After compaction: ${allMessages.length} messages this run`);
    await saveCheckpoint(allMessages);

    // Merge this run into the growing per-contact archive, then export the FULL
    // archive so the saved file is always the complete history we've gathered.
    const { archive, added } = await mergeIntoArchive(threadPhone, allMessages);
    const archiveMsgs = archive.messages;
    log(`This run added ${added} new message(s). Archive now ${archive.count}.`);

    const filtered = await applyFilters(archiveMsgs, options);
    let toExport = filtered;

    if (toExport.length === 0 && archiveMsgs.length > 0) {
      log('WARNING: filter matched 0 — exporting all');
      setStatus(`Filter matched 0 of ${archiveMsgs.length} messages. Exporting all…`);
      await sleep(2500);
      toExport = archiveMsgs;
    }

    const { fname } = await downloadFile(dirHandle, toExport, options.format || 'json', threadPhone);

    const imageCount = toExport.reduce((n, m) => n + (m.attachments?.length || 0), 0);
    const phoneSlug = (threadPhone.digits || 'unknown').slice(-10);
    const range = dateRange(toExport);
    const rangeText = `${fmtDate(range.earliest)} → ${fmtDate(range.latest)}`;
    log(`Attachment summary: ${imageCount} URL(s) across ${toExport.filter((m) => (m.attachments?.length || 0) > 0).length} message(s)`);
    const summary = `Archive: ${toExport.length} messages covering ${rangeText} (+${added} new this run). ${imageCount} image(s).`;
    setStatus(summary);
    log(summary);
    publishProgress({ phase: 'done', status: summary, total: toExport.length, earliest: range.earliest, latest: range.latest, added });

    // Record this run in history
    const historyEntry = {
      id: Date.now(),
      exportedAt: new Date().toISOString(),
      phone: threadPhone.formatted || 'Unknown',
      digits: threadPhone.digits || '',
      sourceUrl: location.href,
      messageCount: toExport.length,
      totalMessages: archive.count,
      imageCount,
      filename: fname,
      folderName: dirHandle.name,
      imageSubfolder: imageCount > 0 ? `images/${phoneSlug}` : null,
      format: options.format || 'json',
      filter: options.filter || '',
      earliest: range.earliest,
      latest: range.latest,
      coverage: rangeText,
      addedThisRun: added,
      mode,
    };
    try {
      const stored = await new Promise((r) => chrome.storage.local.get({ exportHistory: [] }, r));
      const history = [historyEntry, ...stored.exportHistory].slice(0, 100);
      await new Promise((r) => chrome.storage.local.set({ exportHistory: history }, r));
      log('History saved, total runs:', history.length);
    } catch (e) {
      log('History save failed:', e.message);
    }

    // Download images from the FULL archive (toExport), not just this run —
    // otherwise images from earlier runs would be counted but never saved.
    const dlBtn = document.getElementById('gve-dl-images');
    if (dlBtn && imageCount > 0) {
      dlBtn.textContent = `Re-download ${imageCount} image(s)`;
      dlBtn.style.display = '';
      dlBtn.onclick = async () => {
        dlBtn.disabled = true;
        stopRequested = false;
        await downloadImages(dirHandle, toExport, threadPhone);
        dlBtn.disabled = false;
      };
    }

    // AUTO-DOWNLOAD: fetch every image in the archive as soon as the export
    // finishes, so nothing is missed. Idempotent — re-downloading overwrites the
    // same hash-named file. Skipped only if the user hit Stop.
    let imgResult = null;
    if (imageCount > 0 && !stopRequested) {
      publishProgress({ phase: 'images', status: `Downloading ${imageCount} images…`, total: toExport.length, earliest: range.earliest, latest: range.latest });
      setStatus(`Auto-downloading ${imageCount} image(s)…`);
      imgResult = await downloadImages(dirHandle, toExport, threadPhone, { skipExisting: true });
      publishProgress({ phase: 'done', status: `Done. Images: ${imgResult.done}/${imgResult.total} saved${imgResult.failed ? `, ${imgResult.failed} failed` : ''}.`, total: toExport.length, earliest: range.earliest, latest: range.latest });
    }

    await clearCheckpoint();

    // Open history tab
    chrome.runtime.sendMessage({ type: 'open-history' });

    log('--- Export done ---');
    const imgMsg = imgResult ? ` ${imgResult.done}/${imgResult.total} images saved.` : '';
    return { message: `Exported ${toExport.length} messages.${imgMsg}` };
  })().finally(() => { activeExport = null; });

  return activeExport;
}

// ============================================================
// Message listener
// ============================================================
chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type === 'ping') {
    sendResponse({ ok: true });
    return false;
  }

  if (message?.type === 'stop-export') {
    stopRequested = true;
    setStatus('Stopping…');
    log('Stop via popup');
    sendResponse({ ok: true, message: 'Stop requested.' });
    return false;
  }

  if (message?.type === 'start-export') {
    startExport(message.options || {})
      .then((result) => sendResponse({ ok: true, ...result }))
      .catch((error) => {
        log('Export error:', error.message, error.stack);
        setStatus(`Export failed: ${error.message}`);
        sendResponse({ ok: false, message: error.message });
      });
    return true;
  }

  if (message?.type === 'check-checkpoint') {
    loadCheckpoint().then((cp) => {
      sendResponse({ ok: true, checkpoint: cp ? { count: cp.count, savedAt: cp.savedAt } : null });
    });
    return true;
  }

  // Re-sync: download any missing images from the saved archive (no re-scrolling).
  if (message?.type === 'resync-images') {
    resyncImages()
      .then((result) => sendResponse({ ok: true, ...result }))
      .catch((error) => {
        log('Re-sync error:', error.message);
        setStatus(`Re-sync failed: ${error.message}`);
        sendResponse({ ok: false, message: error.message });
      });
    return true;
  }

  // Popup asks "what do we already have for this thread?" so it can label
  // coverage and offer newer / earlier / full.
  if (message?.type === 'check-archive') {
    const tp = detectThreadPhone();
    loadArchive(tp).then((a) => {
      sendResponse({
        ok: true,
        phone: tp.formatted || '',
        archive: a && a.count > 0
          ? { count: a.count, earliest: a.earliest, latest: a.latest,
              earliestLabel: fmtDate(a.earliest), latestLabel: fmtDate(a.latest) }
          : null,
      });
    });
    return true;
  }

  return false;
});

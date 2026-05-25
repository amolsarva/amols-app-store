// ============================================================
// Logging
// ============================================================
const GVE_PREFIX = '[GV-Exporter]';
const logBuffer = [];

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
    <strong>Google Voice Exporter</strong>
    <div id="gve-status">Idle.</div>
    <pre id="gve-log"></pre>
    <div id="gve-buttons">
      <button type="button" id="gve-stop">Stop</button>
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
  node.querySelector('#gve-open-tab').addEventListener('click', () => {
    if (lastExportData) {
      openInNewTab(lastExportData.content, lastExportData.mime);
    } else {
      setStatus('No export available yet — run an export first.');
    }
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
  // Angular CDK virtual scroll viewport is the strongest signal
  const cdkViewport = document.querySelector('cdk-virtual-scroll-viewport');
  if (cdkViewport) {
    log('Thread panel: cdk-virtual-scroll-viewport');
    return cdkViewport;
  }

  // Google Voice custom elements
  for (const sel of ['gv-thread', 'gv-thread-body', '[data-thread-id]']) {
    const el = document.querySelector(sel);
    if (el) { log('Thread panel:', sel); return el; }
  }

  // Walk up from the compose textarea to find a column-width scrollable container
  const compose = document.querySelector(
    'textarea[placeholder], [contenteditable][aria-label*="message" i], textarea[aria-label*="message" i]'
  );
  if (compose) {
    let el = compose.parentElement;
    for (let i = 0; i < 20 && el && el !== document.body; i++, el = el.parentElement) {
      const rect = el.getBoundingClientRect();
      if (rect.width > 300 && rect.height > 400 && el.scrollHeight - el.clientHeight > 50) {
        log('Thread panel via compose box at depth', i, el.tagName, el.className.slice(0, 40));
        return el;
      }
    }
    // Even if no scrollable ancestor found, return the closest big container
    let best = compose.parentElement;
    for (let i = 0; i < 20 && best && best !== document.body; i++, best = best.parentElement) {
      const rect = best.getBoundingClientRect();
      if (rect.width > 300 && rect.height > 300) {
        log('Thread panel (non-scroll) via compose box at depth', i);
        return best;
      }
    }
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
  return elements.filter((el) => !elements.some((other) => other !== el && el.contains(other)));
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
function extractAttachmentUrls(element) {
  const urls = [];
  let skippedSmallImages = 0;
  let skippedDataUrls = 0;
  for (const node of element.querySelectorAll('img[src], video[src], audio[src], a[href]')) {
    const url = node.src || node.currentSrc || node.href || '';
    if (!url || url.startsWith('data:')) {
      if (url.startsWith('data:')) skippedDataUrls++;
      continue;
    }
    if (node.tagName === 'IMG') {
      const w = node.naturalWidth || node.width || 999;
      const h = node.naturalHeight || node.height || 999;
      if (w <= 40 || h <= 40) {
        skippedSmallImages++;
        continue; // skip icons/avatars
      }
    }
    urls.push(url);
  }
  const unique = [...new Set(urls)];
  if (unique.length > 0 || skippedSmallImages > 0 || skippedDataUrls > 0) {
    log(
      `Attachment scan: kept=${unique.length}, skippedSmallImages=${skippedSmallImages}, skippedDataUrls=${skippedDataUrls}`,
      unique.slice(0, 3).map((url) => url.slice(0, 120))
    );
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
    const window = messages.slice(Math.max(0, i - 6), i).concat(messages.slice(i + 1, i + 7));
    return !window.some(
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
async function autoScrollToTop(threadPanel, threadPhone) {
  const scroller = bestScrollContainer(threadPanel);
  const root = threadPanel || document;

  log('Scroller:', scroller.tagName, scroller.id || '', 'scrollHeight:', scroller.scrollHeight, 'clientHeight:', scroller.clientHeight);

  const accumulator = new Map(); // id → message

  function collectVisible() {
    const msgs = extractMessages({ root, threadPhone });
    let added = 0;
    for (const m of msgs) {
      if (!accumulator.has(m.id)) { accumulator.set(m.id, m); added++; }
      else {
        // Update if richer text
        const ex = accumulator.get(m.id);
        if (m.text.length > ex.text.length || m.attachments.length > ex.attachments.length) {
          accumulator.set(m.id, m);
        }
      }
    }
    return added;
  }

  // Initial collection from wherever we are
  collectVisible();
  log(`Initial collection: ${accumulator.size} messages`);

  // Scroll to bottom first so we capture recent messages, then work up
  scroller.scrollTop = scroller.scrollHeight;
  scroller.dispatchEvent(new Event('scroll', { bubbles: true }));
  await sleep(1200);
  collectVisible();

  let stablePasses = 0;
  let lastSize = accumulator.size;
  let lastScrollTop = scroller.scrollTop;
  let pass = 0;
  const CHUNK = 600; // px to scroll up per pass

  while (!stopRequested && stablePasses < 6 && pass < 600) {
    pass++;

    const currentTop = scroller.scrollTop;
    const newTop = Math.max(0, currentTop - CHUNK);
    scroller.scrollTop = newTop;

    // Dispatch both scroll and wheel to maximize Angular CDK compatibility
    scroller.dispatchEvent(new Event('scroll', { bubbles: true }));
    scroller.dispatchEvent(new WheelEvent('wheel', { deltaY: -(CHUNK), bubbles: true, cancelable: true }));
    window.dispatchEvent(new Event('scroll'));

    await sleep(1000);

    const added = collectVisible();
    const total = accumulator.size;

    const atTop = scroller.scrollTop <= 2;
    const grew = total > lastSize;
    const moved = Math.abs(scroller.scrollTop - lastScrollTop) > 2;

    if (!grew && (atTop || !moved)) {
      stablePasses++;
    } else {
      stablePasses = 0;
    }

    lastSize = total;
    lastScrollTop = scroller.scrollTop;

    setStatus(`Scrolling… pass ${pass}, +${added} new, ${total} total, stable ${stablePasses}/6`);
    log(`Pass ${pass}: top=${currentTop}→${scroller.scrollTop}, added=${added}, total=${total}, stable=${stablePasses}`);

    if (pass % 10 === 0) {
      await saveCheckpoint(getSortedAccumulator(accumulator));
    }
  }

  log(`Scroll done: ${pass} passes, ${accumulator.size} messages accumulated`);
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
// Download + new-tab fallback
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
    log(`Debug/download text triggered: ${fname} (${content.length} bytes)`);
  } catch (e) {
    log('Raw text download failed:', e.message);
  }
}

function openInNewTab(content, mime) {
  try {
    const blob = new Blob([content], { type: `${mime};charset=utf-8` });
    const url = URL.createObjectURL(blob);
    window.open(url, '_blank');
    log('Opened in new tab');
    setTimeout(() => URL.revokeObjectURL(url), 120_000);
  } catch (e) {
    log('Open-in-tab failed:', e.message);
  }
}

async function downloadFile(messages, format) {
  const content = serialize(messages, format);
  const mime = format === 'json' ? 'application/json' : format === 'csv' ? 'text/csv' : 'text/plain';
  const fname = makeFilename(format);
  lastExportData = { content, mime };
  log(`Downloading: ${fname} (${content.length} bytes, ${messages.length} messages)`);
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
    log('Download triggered');
    setTimeout(() => URL.revokeObjectURL(url), 120_000);
  } catch (e) {
    log('Download failed, opening in new tab:', e.message);
    openInNewTab(content, mime);
  }
}

// ============================================================
// Image downloading (Phase 2)
// ============================================================
async function downloadImages(messages) {
  const urls = [...new Set(messages.flatMap((m) => m.attachments).filter(Boolean))];
  if (urls.length === 0) { setStatus('No images found.'); return; }
  log(`Downloading ${urls.length} images`);
  let done = 0, failed = 0;
  for (const url of urls) {
    if (stopRequested) break;
    try {
      const resp = await fetch(url, { credentials: 'include' });
      if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
      const blob = await resp.blob();
      const ext = (blob.type.split('/')[1] || 'jpg').replace(/;.*/, '');
      const objUrl = URL.createObjectURL(blob);
      const link = document.createElement('a');
      link.href = objUrl;
      link.download = `gv-img-${hashText(url)}.${ext}`;
      link.style.display = 'none';
      document.documentElement.appendChild(link);
      link.click();
      link.remove();
      setTimeout(() => URL.revokeObjectURL(objUrl), 60_000);
      done++;
      setStatus(`Downloading images… ${done}/${urls.length}`);
      await sleep(400);
    } catch (e) {
      failed++;
      log(`Image failed (${url.slice(0, 70)}): ${e.message}`);
    }
  }
  const s = `Images: ${done} downloaded, ${failed} failed of ${urls.length}.`;
  setStatus(s); log(s);
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

  activeExport = (async () => {
    const checkpoint = await loadCheckpoint();
    if (checkpoint) log(`Checkpoint: ${checkpoint.count} msgs from ${checkpoint.savedAt}`);

    let allMessages;

    if (options.resume && checkpoint?.messages?.length > 0) {
      log('Resuming from checkpoint, skipping scroll');
      setStatus(`Resuming from ${checkpoint.count} saved messages…`);
      allMessages = checkpoint.messages;
    } else {
      setStatus('Finding thread panel…');
      const threadPanel = getThreadPanel();
      log('Thread panel found:', threadPanel ? threadPanel.tagName : 'none');

      setStatus('Scrolling to load full history…');
      allMessages = await autoScrollToTop(threadPanel, threadPhone);

      // Merge with any existing checkpoint so a stopped run isn't fully lost
      if (checkpoint?.messages?.length > 0) {
        const merged = new Map(checkpoint.messages.map((m) => [m.id, m]));
        for (const m of allMessages) merged.set(m.id, m);
        allMessages = getSortedAccumulator(merged);
        log(`Merged with checkpoint: ${allMessages.length} total`);
      }
    }

    if (stopRequested) { setStatus('Stopped.'); return { message: 'Stopped.' }; }

    allMessages = compactNestedMessages(allMessages);
    log(`After compaction: ${allMessages.length} messages`);
    await saveCheckpoint(allMessages);

    const filtered = await applyFilters(allMessages, options);
    let toExport = filtered;

    if (toExport.length === 0 && allMessages.length > 0) {
      log('WARNING: filter matched 0 — exporting all');
      setStatus(`Filter matched 0 of ${allMessages.length} messages. Exporting all…`);
      await sleep(2500);
      toExport = allMessages;
    }

    await downloadFile(toExport, options.format || 'json');

    const imageCount = allMessages.reduce((n, m) => n + m.attachments.length, 0);
    const messagesWithImages = allMessages.filter((m) => m.attachments.length > 0).length;
    log(`Attachment summary: ${imageCount} URL(s) across ${messagesWithImages} message(s)`);
    if (messagesWithImages > 0) {
      log('Attachment samples:', allMessages
        .filter((m) => m.attachments.length > 0)
        .slice(0, 5)
        .map((m) => ({ id: m.id, timestamp: m.timestamp, attachments: m.attachments.slice(0, 3) })));
    }
    const summary = `Exported ${toExport.length} messages from ${allMessages.length} total. ${imageCount} image(s) found.`;
    setStatus(summary);
    log(summary);

    const dlBtn = document.getElementById('gve-dl-images');
    if (dlBtn && imageCount > 0) {
      dlBtn.textContent = `Download ${imageCount} image(s)`;
      dlBtn.style.display = '';
      dlBtn.onclick = async () => {
        dlBtn.disabled = true;
        stopRequested = false;
        await downloadImages(allMessages);
        dlBtn.disabled = false;
      };
    }

    await clearCheckpoint();
    log('--- Export done ---');
    return { message: `Exported ${toExport.length} messages.` };
  })().finally(() => { activeExport = null; });

  return activeExport;
}

// ============================================================
// Message listener
// ============================================================
chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
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

  return false;
});

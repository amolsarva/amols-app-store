#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const crypto = require('node:crypto');
const path = require('node:path');
const readline = require('node:readline/promises');
const { stdin, stdout } = require('node:process');
const { Select, MultiSelect, Input } = require('enquirer');
const qrcode = require('qrcode-terminal');
const { Client, LocalAuth } = require('whatsapp-web.js');
const puppeteer = require('puppeteer');
const {
  aggregateMatches, contextSnippet, deliverOne, deliveryChoice, isPrivateChatId, messageChatId, messageFingerprint, randomDelay,
  repliesAfter, sendTextInPage, sleep, writeJsonAtomic,
} = require('./core');
const { DEFAULT_CHAT_STORAGE, searchNativeHistory } = require('./native-history');

const ROOT = path.resolve(__dirname, '..');
const AUTH_DIR = path.join(ROOT, '.wwebjs_auth');
const ARCHIVE_DIR = path.join(ROOT, 'campaign-archive');
const LOG_DIR = path.join(ROOT, 'logs');
const LOG_FILE = path.join(LOG_DIR, 'whatsapp-campaign-studio.jsonl');
const CONFIG_FILE = path.join(ROOT, 'config.json');
const DEFAULT_CONFIG = {
  searchPageSize: 100, searchPages: 50, fallbackMessagesPerChat: 0, replyScanLimit: 500,
  minimumDelayMs: 2500, maximumDelayMs: 5000, browserHeadless: true,
  browserExecutable: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
};

const args = new Set(process.argv.slice(2));
let liveMode = false;
let dryRun = true;

function log(event, data = {}) {
  fs.mkdirSync(LOG_DIR, { recursive: true });
  const record = { at: new Date().toISOString(), event, mode: dryRun ? 'dry-run' : 'live', ...data };
  fs.appendFileSync(LOG_FILE, `${JSON.stringify(record)}\n`, { mode: 0o600 });
}

function loadConfig() {
  if (!fs.existsSync(CONFIG_FILE)) return DEFAULT_CONFIG;
  return { ...DEFAULT_CONFIG, ...JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8')) };
}

function browserExecutable(config) {
  if (config.browserExecutable && fs.existsSync(config.browserExecutable)) return config.browserExecutable;
  try { return puppeteer.executablePath(); } catch { return ''; }
}

function header(title, subtitle = '') {
  console.clear();
  console.log('\x1b[30;46;1m  WHATSAPP CAMPAIGN STUDIO                                      \x1b[0m');
  console.log(`\n\x1b[1m${title}\x1b[0m`);
  if (subtitle) console.log(`\x1b[36m${subtitle}\x1b[0m`);
  console.log(`\n${dryRun ? '\x1b[33;1mDRY RUN — Messages will not be contacted\x1b[0m' : '\x1b[31;1mLIVE MODE — real WhatsApp messages can be sent\x1b[0m'}\n`);
}

async function pause(message = 'Press Enter to continue') {
  const rl = readline.createInterface({ input: stdin, output: stdout });
  await rl.question(`\n${message}`); rl.close();
}

async function chooseRunMode() {
  if (args.has('--live') && args.has('--dry-run')) {
    throw new Error('Choose only one launch mode: --live or --dry-run');
  }
  if (args.has('--live')) {
    liveMode = true;
  } else if (args.has('--dry-run')) {
    liveMode = false;
  } else {
    header('Choose a mode', 'You can change modes by quitting and relaunching.');
    const mode = await new Select({
      message: 'How should this session run?',
      choices: [
        'Dry run — preview and log; contact nobody',
        'Live mode — send real WhatsApp messages',
      ],
    }).run();
    liveMode = mode.startsWith('Live mode');
  }
  dryRun = !liveMode;
}

async function confirmRecipient(person, body, index, total, approveAll) {
  header(`${dryRun ? 'Simulate' : 'Send'} message ${index + 1} of ${total}`, `${person.name} · ${person.chatId}`);
  console.log('\x1b[1mExact message:\x1b[0m');
  console.log(`\n${body}\n`);
  if (approveAll) {
    console.log('\x1b[36;1mALL YES is active — continuing automatically.\x1b[0m');
    return 'yes';
  }
  while (true) {
    const raw = await new Input({
      message: `${dryRun ? 'Simulate for' : 'Send to'} ${person.name}? [Y]es / [n]o / [a]ll yes / [q]uit`,
    }).run();
    const choice = deliveryChoice(raw);
    if (choice) return choice;
    console.log('Please enter y, n, a, or q. Enter by itself means yes.');
  }
}

async function multiline(message, initial = '') {
  header(message, 'Enter as many lines as needed. Type .done alone to finish.');
  if (initial) console.log(`Starting text:\n${initial}\n`);
  const rl = readline.createInterface({ input: stdin, output: stdout });
  const lines = initial ? [initial] : [];
  while (true) {
    const line = await rl.question(lines.length ? '' : '> ');
    if (line === '.done') break;
    lines.push(line);
  }
  rl.close();
  return lines.join('\n').trim();
}

async function doctor() {
  const config = loadConfig();
  const checks = [];
  const add = (name, ok, detail) => checks.push({ name, ok, detail });
  add('Node.js >= 18', Number(process.versions.node.split('.')[0]) >= 18, process.version);
  const browser = browserExecutable(config);
  add('Chrome/Chromium executable', Boolean(browser && fs.existsSync(browser)), browser || 'not found');
  add('Native WhatsApp history database', fs.existsSync(DEFAULT_CHAT_STORAGE),
    fs.existsSync(DEFAULT_CHAT_STORAGE) ? DEFAULT_CHAT_STORAGE : 'Mac WhatsApp database not found; Web scan fallback will be used');
  const disk = fs.statfsSync(ROOT);
  const freeBytes = Number(disk.bavail) * Number(disk.bsize);
  add('At least 250 MB free', freeBytes >= 250 * 1024 * 1024, `${Math.round(freeBytes / 1024 / 1024)} MB free`);
  for (const [name, directory] of [['app folder', ROOT], ['auth folder', AUTH_DIR], ['log folder', LOG_DIR], ['archive folder', ARCHIVE_DIR]]) {
    try { fs.mkdirSync(directory, { recursive: true }); fs.accessSync(directory, fs.constants.W_OK); add(`${name} writable`, true, directory); }
    catch (error) { add(`${name} writable`, false, error.message); }
  }
  add('Configuration', fs.existsSync(CONFIG_FILE), fs.existsSync(CONFIG_FILE) ? CONFIG_FILE : 'installer will create it');
  console.log('\nWhatsApp Campaign Studio doctor\n');
  for (const c of checks) console.log(`${c.ok ? '✓' : '✗'} ${c.name}: ${c.detail}`);
  const failed = checks.filter((c) => !c.ok && c.name !== 'Configuration');
  log('doctor_completed', { passed: checks.length - failed.length, failed: failed.length });
  process.exitCode = failed.length ? 1 : 0;
}

function createClient(config) {
  return new Client({
    authStrategy: new LocalAuth({ dataPath: AUTH_DIR, clientId: 'campaign-studio' }),
    puppeteer: { headless: config.browserHeadless, executablePath: browserExecutable(config) },
  });
}

async function sendTextDirect(client, chatId, body) {
  return client.pupPage.evaluate(sendTextInPage, { chatId, body });
}

async function recentMessagesDirect(client, chatId, limit) {
  return client.pupPage.evaluate(async ({ chatId, limit }) => {
    const collections = window.require('WAWebCollections');
    const wid = window.require('WAWebWidFactory').createWid(chatId);
    const chat = collections.Chat.get(wid) || collections.Chat.get(chatId);
    if (!chat) return [];
    let messages = chat.msgs?.getModelsArray?.() || [];
    while (messages.length < limit) {
      const loaded = await window.require('WAWebChatLoadMessages').loadEarlierMsgs({ chat });
      if (!loaded || !loaded.length) break;
      messages = [...loaded, ...messages];
    }
    return messages.slice(-limit).map((message) => ({
      fromMe: Boolean(message.id?.fromMe), timestamp: Number(message.t) || 0,
    }));
  }, { chatId, limit });
}

async function connect(client) {
  header('Connecting to WhatsApp', 'The first run requires Linked devices → Link a device on your phone.');
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Timed out waiting for WhatsApp after 5 minutes')), 300000);
    client.on('qr', (qr) => { console.log('\nScan this QR code with WhatsApp:\n'); qrcode.generate(qr, { small: true }); log('qr_presented'); });
    client.on('authenticated', () => log('authenticated'));
    client.on('auth_failure', (message) => { clearTimeout(timer); reject(new Error(`Authentication failed: ${message}`)); });
    client.on('disconnected', (reason) => log('disconnected', { reason: String(reason) }));
    client.on('ready', () => { clearTimeout(timer); log('client_ready'); resolve(); });
    client.initialize().catch(reject);
  });
}

async function searchAll(client, query, config) {
  const found = new Map();
  const chatNameCache = new Map();
  let globalSearchWorked = true;
  try {
    for (let page = 0; page < config.searchPages; page += 1) {
      const messages = await client.searchMessages(query, { page, limit: config.searchPageSize });
      for (const m of messages) found.set(m.id._serialized, m);
      if (messages.length < config.searchPageSize) break;
    }
  } catch (error) {
    globalSearchWorked = false;
    log('global_search_failed', { error: error.stack || String(error) });
    console.log('WhatsApp global search is unavailable.');
  }

  // Global search only covers WhatsApp Web's current search index, which is often
  // much smaller than the history actually available to each chat. Scan the live
  // in-page collections directly; this intentionally bypasses whatsapp-web.js's
  // getChats/getChatById wrappers, which break when WA renames _serialized to $1.
  console.log('Scanning all available private chats for a complete result…');
  const pageDirectory = await client.pupPage.evaluate(() => {
    const chats = window.require('WAWebCollections').Chat.getModelsArray();
    const contacts = window.require('WAWebCollections').Contact.getModelsArray();
    const serialized = (value) => {
      if (!value) return '';
      return value._serialized || value.$1 || value.toString?.() || '';
    };
    return {
      chats: chats.map((chat) => ({
        id: serialized(chat.id),
        name: String(chat.formattedTitle || chat.name || serialized(chat.id)),
        isGroup: Boolean(chat.groupMetadata) || serialized(chat.id).endsWith('@g.us'),
      })).filter((chat) => !chat.id.includes('@newsletter') &&
        (chat.isGroup || chat.id.endsWith('@c.us') || chat.id.endsWith('@lid'))),
      contacts: contacts.map((contact) => ({
        id: serialized(contact.id),
        name: String(contact.pushname || contact.name || contact.shortName || contact.formattedName || ''),
      })).filter((contact) => contact.id),
    };
  });
  const searchableChats = pageDirectory.chats;
  for (const contact of pageDirectory.contacts) {
    if (contact.name) chatNameCache.set(contact.id, contact.name);
  }
  const messageLimit = Number(config.fallbackMessagesPerChat) > 0
    ? Number(config.fallbackMessagesPerChat) : 0;
  let scannedMessages = 0;
  let skippedChats = 0;
  const needle = query.toLocaleLowerCase();
  let groupAuthorMatches = 0;
  for (let index = 0; index < searchableChats.length; index += 1) {
    const chat = searchableChats[index];
    const chatId = chat.id;
    if (!chat.isGroup) chatNameCache.set(chatId, chat.name || chatId.replace(/@.+$/, ''));
    process.stdout.write(`\rScanning chat ${index + 1}/${searchableChats.length} · ${found.size} matching messages…`);
    try {
      const result = await client.pupPage.evaluate(async ({ chatId, chatName, isGroup, needle, messageLimit }) => {
        const serialized = (value) => {
          if (!value) return '';
          return value._serialized || value.$1 || value.toString?.() || '';
        };
        const collections = window.require('WAWebCollections');
        const wid = window.require('WAWebWidFactory').createWid(chatId);
        const chatModel = collections.Chat.get(wid) || collections.Chat.get(chatId);
        if (!chatModel) return { hits: [], scanned: 0, unavailable: true };
        const hits = [];
        const seen = new Set();
        let scanned = 0;
        const consume = (messages) => {
          for (const message of messages || []) {
            const id = serialized(message.id) || `${chatId}:${message.t}:${scanned}`;
            if (seen.has(id)) continue;
            seen.add(id); scanned += 1;
            const body = String(message.body || message.caption || '');
            if (body.toLocaleLowerCase().includes(needle)) {
              let recipientId = chatId;
              if (isGroup) {
                if (message.id?.fromMe) continue;
                recipientId = serialized(message.author || message.id?.participant || message.from);
                if (!(recipientId.endsWith('@c.us') || recipientId.endsWith('@lid'))) continue;
              }
              hits.push({ id, chatId: recipientId, body: isGroup ? `[${chatName}] ${body}` : body,
                timestamp: Number(message.t) || 0, fromGroup: isGroup });
            }
          }
        };
        consume(chatModel.msgs?.getModelsArray?.() || []);
        let rounds = 0;
        while ((messageLimit === 0 || scanned < messageLimit) && rounds < 1000) {
          const loaded = await window.require('WAWebChatLoadMessages').loadEarlierMsgs({ chat: chatModel });
          if (!loaded || !loaded.length) break;
          const before = scanned;
          consume(loaded);
          rounds += 1;
          if (scanned === before) break;
        }
        return { hits, scanned, unavailable: false };
      }, { chatId, chatName: chat.name, isGroup: chat.isGroup, needle, messageLimit });
      scannedMessages += result.scanned;
      for (const message of result.hits) {
        if (message.fromGroup) groupAuthorMatches += 1;
        found.set(message.id, message);
      }
    } catch (error) {
      skippedChats += 1;
      log('chat_scan_skipped', { chatId, error: error.stack || String(error) });
    }
  }
  process.stdout.write('\n');

  const normalized = [];
  let skippedMalformed = 0;
  for (const message of found.values()) {
    const chatId = message.chatId || messageChatId(message);
    if (!isPrivateChatId(chatId)) { skippedMalformed += 1; continue; }
    if (!chatNameCache.has(chatId)) {
      let name = chatId.replace(/@.+$/, '');
      try {
        const contact = await client.getContactById(chatId);
        name = contact.pushname || contact.name || contact.shortName || name;
      } catch (error) {
        log('contact_lookup_skipped', { chatId, error: error.stack || String(error) });
      }
      chatNameCache.set(chatId, name || chatId.replace(/@.+$/, ''));
    }
    normalized.push({ chatId, chatName: chatNameCache.get(chatId), timestamp: message.timestamp, body: message.body });
  }
  const recipients = aggregateMatches(normalized);
  log('search_completed', { query, searchMethod: 'global-plus-full-history-scan',
    globalSearchWorked, searchableChats: searchableChats.length, skippedChats, scannedMessages,
    groupAuthorMatches, rawMatches: found.size, skippedMalformed, privateRecipients: recipients.length });
  return recipients;
}

function archiveList() {
  fs.mkdirSync(ARCHIVE_DIR, { recursive: true });
  return fs.readdirSync(ARCHIVE_DIR).filter((f) => f.endsWith('.json')).map((file) => {
    try { return { file, ...JSON.parse(fs.readFileSync(path.join(ARCHIVE_DIR, file), 'utf8')) }; }
    catch { return null; }
  }).filter(Boolean).sort((a, b) => b.createdAt.localeCompare(a.createdAt));
}

function saveCampaign(campaign) {
  const id = campaign.id || crypto.randomUUID();
  const file = path.join(ARCHIVE_DIR, `${campaign.createdAt.slice(0, 10)}-${id.slice(0, 8)}.json`);
  writeJsonAtomic(file, { id, ...campaign });
  return file;
}

async function chooseRecipients(recipients, query) {
  header(`${recipients.length} people matched “${query}”`, 'Direct-chat matches and individual group-message authors; destinations remain private.');
  for (const recipient of recipients) {
    console.log(`\n\x1b[1;36m${recipient.name}\x1b[0m · ${recipient.matches} match${recipient.matches === 1 ? '' : 'es'}`);
    for (const snippet of recipient.snippets.slice(0, 3)) {
      console.log(`  • ${contextSnippet(snippet, query)}`);
    }
  }
  await pause('Press Enter to review and choose recipients');
  header(`${recipients.length} people matched “${query}”`, 'Everyone starts selected. Space toggles; a selects all; i inverts; Enter continues.');
  const selected = await new MultiSelect({
    name: 'recipients', message: 'Who should receive a separate message?', limit: 18,
    initial: recipients.map((_, index) => index),
    choices: recipients.map((r) => ({
      name: r.chatId, value: r.chatId,
      message: `${r.name}  · ${r.matches} match${r.matches === 1 ? '' : 'es'} · ${new Date(r.lastTimestamp * 1000).toLocaleDateString()}`,
      enabled: true,
    })),
  }).run();
  const chosen = recipients.filter((r) => selected.includes(r.chatId));
  if (!chosen.length) {
    console.log('\nNo recipients selected. Returning without composing or sending.');
    await pause();
  }
  return chosen;
}

async function deliver(client, config, query, chosen, body, parentCampaignId = null) {
  const sent = [], simulatedRecipients = [], skipped = [], uncertain = [], failed = [];
  let approveAll = false;
  let quitEarly = false;
  log('delivery_started', { query, recipientCount: chosen.length, bodyFingerprint: messageFingerprint(body) });
  for (let index = 0; index < chosen.length; index += 1) {
    const person = chosen[index];
    const alreadyApprovedAll = approveAll;
    const choice = await confirmRecipient(person, body, index, chosen.length, approveAll);
    log('recipient_decision', { chatId: person.chatId, campaignIndex: index + 1,
      decision: alreadyApprovedAll ? 'all-yes active' : choice });
    if (choice === 'all') approveAll = true;
    if (choice === 'no') {
      skipped.push({ chatId: person.chatId, name: person.name, reason: 'user skipped' });
      log('recipient_skipped', { chatId: person.chatId, campaignIndex: index + 1, reason: 'user skipped' });
      continue;
    }
    if (choice === 'quit') {
      quitEarly = true;
      for (const remaining of chosen.slice(index)) {
        skipped.push({ chatId: remaining.chatId, name: remaining.name, reason: 'campaign quit' });
      }
      log('delivery_quit', { campaignIndex: index + 1, remaining: chosen.length - index });
      break;
    }
    if (dryRun) {
      await deliverOne({ dryRun: true, person, body, send: (...values) => client.sendMessage(...values) });
      console.log(`[SIMULATED ${index + 1}/${chosen.length}] ${person.name} — WhatsApp not contacted`);
      simulatedRecipients.push({ chatId: person.chatId, name: person.name });
      log('recipient_simulated', { chatId: person.chatId, campaignIndex: index + 1 });
      continue;
    }
    try {
      const delivery = await deliverOne({
        dryRun: false, person, body, send: (...values) => sendTextDirect(client, ...values),
      });
      const result = delivery.result;
      const item = { chatId: person.chatId, name: person.name, sentAt: new Date().toISOString(), messageId: result.id };
      sent.push(item); log('recipient_sent', { chatId: person.chatId, campaignIndex: index + 1 });
    } catch (error) {
      const detail = error?.message || String(error || 'Unknown delivery error');
      if (detail.includes('dispatch could not be verified')) {
        uncertain.push({ chatId: person.chatId, name: person.name, error: detail });
        for (const remaining of chosen.slice(index + 1)) {
          skipped.push({ chatId: remaining.chatId, name: remaining.name, reason: 'halted after unverified dispatch' });
        }
        quitEarly = true;
        log('delivery_halted_unverified', { chatId: person.chatId, campaignIndex: index + 1,
          remaining: chosen.length - index - 1 });
        break;
      }
      failed.push({ chatId: person.chatId, name: person.name, error: detail });
      log('recipient_failed', { chatId: person.chatId, error: detail });
    }
    if (index < chosen.length - 1) await sleep(randomDelay(config.minimumDelayMs, config.maximumDelayMs));
  }
  const campaign = { createdAt: new Date().toISOString(), query, body, bodyFingerprint: messageFingerprint(body),
    dryRun, parentCampaignId, quitEarly, recipients: sent, simulatedRecipients, skipped, uncertain, failed };
  const file = saveCampaign(campaign);
  log('delivery_completed', { sent: sent.length, simulated: simulatedRecipients.length,
    skipped: skipped.length, uncertain: uncertain.length, failed: failed.length, quitEarly, archive: file });
  header(dryRun ? 'Simulation saved — 0 messages sent' : quitEarly ? 'Campaign stopped' : 'Campaign complete',
    `${sent.length} sent · ${simulatedRecipients.length} simulated · ${skipped.length} skipped · ${uncertain.length} uncertain · ${failed.length} failed`);
  console.log(file); await pause();
}

async function newCampaign(client, config) {
  header('New campaign', 'Search the native Mac WhatsApp history for a word or phrase.');
  const query = (await new Input({ message: 'Search phrase' }).run()).trim();
  if (!query) return;
  log('search_started', { query });
  let recipients = [];
  try {
    const native = searchNativeHistory(query);
    if (native) {
      recipients = native.recipients;
      console.log(`Searched ${native.totalMessages.toLocaleString()} messages in the native Mac WhatsApp database.`);
      console.log(`Found ${native.matchMessages} matching messages, including ${native.groupAuthorMatches} from group authors.`);
      log('native_search_completed', { query, totalMessages: native.totalMessages,
        matchMessages: native.matchMessages, groupAuthorMatches: native.groupAuthorMatches,
        recipients: recipients.length, dbPath: native.dbPath });
    }
  } catch (error) {
    log('native_search_failed', { error: error.stack || String(error) });
  }
  if (!recipients.length) {
    console.log('Native history had no usable result; searching available WhatsApp Web history…');
    recipients = await searchAll(client, query, config);
  }
  if (!recipients.length) { header('No private recipient matches', 'No matching native or linked-device messages were found.'); await pause(); return; }
  const chosen = await chooseRecipients(recipients, query);
  if (!chosen.length) return;
  const body = await multiline('Compose the campaign message');
  if (body) await deliver(client, config, query, chosen, body);
}

async function archiveFlow(client, config) {
  const campaigns = archiveList();
  if (!campaigns.length) { header('Campaign archive', 'No campaigns yet.'); await pause(); return; }
  const file = await new Select({ message: 'Campaign', choices: campaigns.map((c) => ({
    name: c.file, value: c.file,
    message: `${c.createdAt.slice(0, 16).replace('T', ' ')} · ${c.dryRun ? 'SIMULATED' : 'SENT'} · ${c.query}`,
  })) }).run();
  const campaign = campaigns.find((c) => c.file === file);
  if (campaign.dryRun) { header('Simulation only — 0 messages sent', `${campaign.simulatedRecipients.length} recipients previewed`); await pause(); return; }
  header('Checking replies', campaign.query);
  const unanswered = []; let replied = 0;
  for (const recipient of campaign.recipients) {
    try {
      const messages = await recentMessagesDirect(client, recipient.chatId, config.replyScanLimit);
      const replies = repliesAfter(messages, Math.floor(new Date(recipient.sentAt).getTime() / 1000));
      if (replies.length) replied += 1;
      else unanswered.push({ chatId: recipient.chatId, name: recipient.name, matches: 0, lastTimestamp: 0, snippets: [] });
    } catch (error) { log('reply_check_failed', { chatId: recipient.chatId, error: error.message }); }
  }
  header('Reply status', `${replied} replied · ${unanswered.length} did not reply`);
  if (!unanswered.length) { await pause(); return; }
  const action = await new Select({ message: 'Next step', choices: ['Review and prepare a bump', 'Return'] }).run();
  if (action.startsWith('Review')) {
    const chosen = await chooseRecipients(unanswered, 'no reply');
    const body = await multiline('Compose the bump', 'Just bumping this in case it got buried — ');
    if (body) await deliver(client, config, campaign.query, chosen, body, campaign.id);
  }
}

async function main() {
  if (args.has('--doctor')) return doctor();
  await chooseRunMode();
  const config = loadConfig();
  log('application_started', { node: process.version });
  const client = createClient(config);
  let stopping = false;
  const stopCleanly = async (signal) => {
    if (stopping) return;
    stopping = true;
    log('application_stopping', { signal });
    try { await client.destroy(); } catch {}
    process.exit(0);
  };
  process.once('SIGINT', () => stopCleanly('SIGINT'));
  process.once('SIGTERM', () => stopCleanly('SIGTERM'));
  try {
    await connect(client);
    while (true) {
      header('Ready', 'Search → review → compose → approve each message → archive → bump unanswered');
      const action = await new Select({ message: 'What would you like to do?', choices: [
        'New campaign — search WhatsApp history', 'Campaign archive — replies and bumps', 'Quit',
      ] }).run();
      if (action.startsWith('New')) await newCampaign(client, config);
      else if (action.startsWith('Campaign')) await archiveFlow(client, config);
      else break;
    }
  } catch (error) {
    const detail = error?.stack || error?.message || String(error || 'Prompt cancelled');
    if (error == null || detail.includes('Aborted with Ctrl+C')) {
      log('application_stopped', { reason: error == null ? 'prompt cancelled' : 'keyboard interrupt' });
      return;
    }
    log('fatal_error', { error: detail });
    console.error(`\nError: ${error?.message || String(error)}\nDetails: ${LOG_FILE}`); process.exitCode = 1;
  } finally { try { await client.destroy(); } catch {} }
}

main();

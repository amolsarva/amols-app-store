'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');
const { aggregateMatches, contextSnippet, deliverOne, deliveryChoice, isPrivateChatId, messageChatId, repliesAfter,
  sendTextInPage } = require('../src/core');
const { searchNativeHistory, webChatId } = require('../src/native-history');

test('private chat filter excludes groups, status, and channels', () => {
  assert.equal(isPrivateChatId('123@c.us'), true);
  assert.equal(isPrivateChatId('123@lid'), true);
  assert.equal(isPrivateChatId('123@g.us'), false);
  assert.equal(isPrivateChatId('status@broadcast'), false);
});

test('search matches aggregate by private recipient', () => {
  const rows = aggregateMatches([
    { chatId: '1@c.us', chatName: 'Ada', timestamp: 10, body: 'Mallorca one' },
    { chatId: '1@c.us', chatName: 'Ada', timestamp: 20, body: 'Mallorca two' },
    { chatId: 'group@g.us', chatName: 'Group', timestamp: 30, body: 'Mallorca' },
  ]);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].name, 'Ada');
  assert.equal(rows[0].matches, 2);
});

test('chat ID is derived without resolving a Chat object', () => {
  assert.equal(messageChatId({ id: { remote: '1@c.us' }, fromMe: false }), '1@c.us');
  assert.equal(messageChatId({ fromMe: true, from: 'me@c.us', to: '2@c.us' }), '2@c.us');
  assert.equal(messageChatId({ fromMe: false, from: '3@lid', to: 'me@c.us' }), '3@lid');
});

test('reply detection requires inbound message after send', () => {
  const replies = repliesAfter([
    { fromMe: false, timestamp: 9 }, { fromMe: true, timestamp: 12 }, { fromMe: false, timestamp: 13 },
  ], 10);
  assert.deepEqual(replies.map((r) => r.timestamp), [13]);
});

test('dry-run delivery cannot invoke the send function', async () => {
  let calls = 0;
  const result = await deliverOne({
    dryRun: true,
    person: { chatId: '1@c.us', name: 'Ada' },
    body: 'hello',
    send: async () => { calls += 1; throw new Error('must never run'); },
  });
  assert.equal(calls, 0);
  assert.equal(result.kind, 'simulated');
});

test('per-recipient answers accept y, n, a, q and friendly variants', () => {
  assert.equal(deliveryChoice('Y'), 'yes');
  assert.equal(deliveryChoice(''), 'yes');
  assert.equal(deliveryChoice('no'), 'no');
  assert.equal(deliveryChoice('A'), 'all');
  assert.equal(deliveryChoice('all yes'), 'all');
  assert.equal(deliveryChoice('quit'), 'quit');
  assert.equal(deliveryChoice('maybe'), null);
});

test('undefined WhatsApp send result is verified from the new outbound chat model', async () => {
  const messages = [];
  const chat = { id: { $1: 'resolved@lid' }, msgs: { getModelsArray: () => messages } };
  const previousWindow = global.window;
  global.window = { WWebJS: {
    getChat: async () => chat,
    sendMessage: async (_chat, body) => {
      messages.push({ id: { $1: 'outbound-1', fromMe: true }, body,
        t: Math.floor(Date.now() / 1000), ack: 2 });
      return undefined;
    },
  } };
  try {
    const result = await sendTextInPage({ chatId: 'original@c.us', body: 'hello' });
    assert.equal(result.id, 'outbound-1');
    assert.equal(result.resolvedChatId, 'resolved@lid');
    assert.equal(result.verifiedBy, 'chat model');
  } finally {
    global.window = previousWindow;
  }
});

test('long context is centered on the matching phrase', () => {
  const text = `${'before '.repeat(80)}Mallorca${' after'.repeat(80)}`;
  const snippet = contextSnippet(text, 'mallorca', 120);
  assert.match(snippet, /Mallorca/);
  assert.ok(snippet.length <= 122);
});

test('native history finds direct contacts and inbound group authors', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-history-test-'));
  const databasePath = path.join(directory, 'ChatStorage.sqlite');
  const contactsPath = path.join(directory, 'ContactsV2.sqlite');
  const db = new DatabaseSync(databasePath);
  db.exec(`
    CREATE TABLE ZWACHATSESSION (Z_PK INTEGER, ZCONTACTJID TEXT, ZPARTNERNAME TEXT, ZCONTACTIDENTIFIER TEXT);
    CREATE TABLE ZWAGROUPMEMBER (Z_PK INTEGER, ZMEMBERJID TEXT, ZCONTACTNAME TEXT, ZFIRSTNAME TEXT);
    CREATE TABLE ZWAMESSAGE (ZTEXT TEXT, ZMESSAGEDATE REAL, ZISFROMME INTEGER, ZPUSHNAME TEXT, ZCHATSESSION INTEGER, ZGROUPMEMBER INTEGER);
    INSERT INTO ZWACHATSESSION VALUES (1, '111@s.whatsapp.net', 'Ada', NULL), (2, 'group@g.us', 'Travel group', NULL);
    INSERT INTO ZWAGROUPMEMBER VALUES (9, '222@lid', 'Grace', NULL);
    INSERT INTO ZWAMESSAGE VALUES ('Mallorca direct', 100, 1, NULL, 1, NULL), ('Mallorca group', 200, 0, NULL, 2, 9), ('Mallorca from me', 300, 1, NULL, 2, NULL);
  `);
  db.close();
  const contacts = new DatabaseSync(contactsPath);
  contacts.exec(`
    CREATE TABLE ZWAADDRESSBOOKCONTACT (ZLID TEXT, ZWHATSAPPID TEXT, ZFULLNAME TEXT, ZBUSINESSNAME TEXT, ZGIVENNAME TEXT, ZLOCALIZEDPHONENUMBER TEXT);
    INSERT INTO ZWAADDRESSBOOKCONTACT VALUES ('222@lid', '222@s.whatsapp.net', 'Grace Hopper', NULL, NULL, NULL);
  `);
  contacts.close();
  const result = searchNativeHistory('mallorca', databasePath, contactsPath);
  assert.equal(result.totalMessages, 3);
  assert.equal(result.matchMessages, 2);
  assert.deepEqual(result.recipients.map((r) => r.chatId).sort(), ['111@c.us', '222@c.us']);
  assert.equal(result.recipients.find((r) => r.chatId === '222@c.us').name, 'Grace Hopper');
  fs.rmSync(directory, { recursive: true, force: true });
});

test('native phone JIDs become WhatsApp Web chat IDs', () => {
  assert.equal(webChatId('123@s.whatsapp.net'), '123@c.us');
  assert.equal(webChatId('456@lid'), '456@lid');
});

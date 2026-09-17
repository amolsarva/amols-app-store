'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

function isPrivateChatId(id) {
  return typeof id === 'string' && (id.endsWith('@c.us') || id.endsWith('@lid'));
}

function messageChatId(message) {
  const remote = message && message.id && message.id.remote;
  if (typeof remote === 'string' && remote) return remote;
  if (message && message.fromMe) return message.to || '';
  return (message && message.from) || '';
}

function aggregateMatches(messages) {
  const people = new Map();
  for (const message of messages) {
    const chatId = message.chatId || message.from || message.to || '';
    if (!isPrivateChatId(chatId)) continue;
    const current = people.get(chatId) || {
      chatId, name: message.chatName || chatId.replace(/@.+$/, ''), matches: 0,
      lastTimestamp: 0, snippets: [],
    };
    current.matches += 1;
    current.lastTimestamp = Math.max(current.lastTimestamp, Number(message.timestamp) || 0);
    const body = String(message.body || '').replace(/\s+/g, ' ').trim();
    if (body && !current.snippets.includes(body)) current.snippets.push(body);
    people.set(chatId, current);
  }
  return [...people.values()].sort((a, b) => b.lastTimestamp - a.lastTimestamp);
}

function repliesAfter(messages, timestamp) {
  return messages
    .filter((m) => !m.fromMe && Number(m.timestamp) > Number(timestamp))
    .sort((a, b) => b.timestamp - a.timestamp);
}

function messageFingerprint(body) {
  return crypto.createHash('sha256').update(body).digest('hex').slice(0, 16);
}

function contextSnippet(body, query, maximum = 360) {
  const text = String(body || '').replace(/\s+/g, ' ').trim();
  if (text.length <= maximum) return text;
  const at = text.toLocaleLowerCase().indexOf(String(query || '').toLocaleLowerCase());
  if (at < 0) return `${text.slice(0, maximum - 1)}…`;
  const room = maximum - 2;
  let start = Math.max(0, at - Math.floor(room / 2));
  let end = Math.min(text.length, start + room);
  start = Math.max(0, end - room);
  return `${start > 0 ? '…' : ''}${text.slice(start, end)}${end < text.length ? '…' : ''}`;
}

function writeJsonAtomic(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(temp, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(temp, file);
}

function sleep(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }

function randomDelay(minimum, maximum) {
  const low = Math.max(0, Number(minimum));
  const high = Math.max(low, Number(maximum));
  return Math.floor(low + Math.random() * (high - low + 1));
}

async function sendTextInPage({ chatId, body }) {
  const serialized = (value) => value?._serialized || value?.$1 || value?.toString?.() || '';
  const chat = await window.WWebJS.getChat(chatId, { getAsModel: false });
  if (!chat) throw new Error(`Private chat is unavailable: ${chatId}`);
  const beforeIds = new Set((chat.msgs?.getModelsArray?.() || []).map((item) => serialized(item.id)));
  const startedAt = Math.floor(Date.now() / 1000) - 2;
  const message = await window.WWebJS.sendMessage(chat, body, {
    linkPreview: true, parseVCards: true, ignoreQuoteErrors: true,
  });
  if (message && serialized(message.id)) {
    return { id: serialized(message.id), timestamp: Number(message.t) || 0,
      resolvedChatId: serialized(chat.id), ack: message.ack, verifiedBy: 'send result' };
  }
  // Current WhatsApp Web can dispatch successfully while returning undefined.
  // Verify the new outbound model in the resolved chat before reporting success.
  for (let attempt = 0; attempt < 40; attempt += 1) {
    const messages = chat.msgs?.getModelsArray?.() || [];
    const match = [...messages].reverse().find((item) => {
      const id = serialized(item.id);
      return Boolean(item.id?.fromMe) && item.body === body && Number(item.t) >= startedAt &&
        id && !beforeIds.has(id);
    });
    if (match) {
      return { id: serialized(match.id), timestamp: Number(match.t) || 0,
        resolvedChatId: serialized(chat.id), ack: match.ack, verifiedBy: 'chat model' };
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error('WhatsApp dispatch could not be verified; stop and inspect the chat before retrying');
}

async function deliverOne({ dryRun, person, body, send }) {
  if (dryRun) return { kind: 'simulated', chatId: person.chatId, name: person.name };
  const result = await send(person.chatId, body);
  return { kind: 'sent', chatId: person.chatId, name: person.name, result };
}

function deliveryChoice(value) {
  const answer = String(value ?? '').trim().toLocaleLowerCase();
  if (!answer || answer === 'y' || answer === 'yes') return 'yes';
  if (answer === 'n' || answer === 'no') return 'no';
  if (answer === 'a' || answer === 'all' || answer === 'all yes') return 'all';
  if (answer === 'q' || answer === 'quit') return 'quit';
  return null;
}

module.exports = {
  aggregateMatches, contextSnippet, deliverOne, deliveryChoice, isPrivateChatId, messageChatId, messageFingerprint, randomDelay,
  repliesAfter, sendTextInPage, sleep, writeJsonAtomic,
};

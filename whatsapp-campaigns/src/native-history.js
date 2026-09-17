'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');
const { aggregateMatches } = require('./core');

const DEFAULT_CHAT_STORAGE = path.join(
  os.homedir(), 'Library', 'Group Containers',
  'group.net.whatsapp.WhatsApp.shared', 'ChatStorage.sqlite',
);
const DEFAULT_CONTACTS_STORAGE = path.join(
  os.homedir(), 'Library', 'Group Containers',
  'group.net.whatsapp.WhatsApp.shared', 'ContactsV2.sqlite',
);

function webChatId(jid) {
  const value = String(jid || '');
  return value.endsWith('@s.whatsapp.net')
    ? `${value.slice(0, -'@s.whatsapp.net'.length)}@c.us`
    : value;
}

function contactDirectory(contactsPath) {
  if (!fs.existsSync(contactsPath)) return new Map();
  const db = new DatabaseSync(contactsPath, { readOnly: true });
  try {
    return new Map(db.prepare(`
      SELECT ZLID AS lid, ZWHATSAPPID AS phoneJid,
             COALESCE(ZFULLNAME, ZBUSINESSNAME, ZGIVENNAME, ZLOCALIZEDPHONENUMBER) AS name
      FROM ZWAADDRESSBOOKCONTACT WHERE ZLID IS NOT NULL
    `).all().map((row) => [row.lid, { phoneJid: row.phoneJid, name: row.name }]));
  } finally { db.close(); }
}

function searchNativeHistory(query, dbPath = DEFAULT_CHAT_STORAGE, contactsPath = DEFAULT_CONTACTS_STORAGE) {
  if (!fs.existsSync(dbPath)) return null;
  const db = new DatabaseSync(dbPath, { readOnly: true });
  try {
    const totalMessages = db.prepare('SELECT COUNT(*) AS count FROM ZWAMESSAGE').get().count;
    const rows = db.prepare(`
      SELECT
        CASE WHEN c.ZCONTACTJID LIKE '%@g.us'
             THEN gm.ZMEMBERJID ELSE c.ZCONTACTJID END AS jid,
        CASE WHEN c.ZCONTACTJID LIKE '%@g.us'
             THEN COALESCE(gm.ZCONTACTNAME, gm.ZFIRSTNAME, m.ZPUSHNAME, gm.ZMEMBERJID)
             ELSE COALESCE(c.ZPARTNERNAME, c.ZCONTACTIDENTIFIER, c.ZCONTACTJID) END AS name,
        CASE WHEN c.ZCONTACTJID LIKE '%@g.us'
             THEN '[' || COALESCE(c.ZPARTNERNAME, 'Group') || '] ' || m.ZTEXT
             ELSE m.ZTEXT END AS body,
        CAST(COALESCE(m.ZMESSAGEDATE, 0) + 978307200 AS INTEGER) AS timestamp,
        CASE WHEN c.ZCONTACTJID LIKE '%@g.us' THEN 1 ELSE 0 END AS fromGroup
      FROM ZWAMESSAGE m
      JOIN ZWACHATSESSION c ON c.Z_PK = m.ZCHATSESSION
      LEFT JOIN ZWAGROUPMEMBER gm ON gm.Z_PK = m.ZGROUPMEMBER
      WHERE instr(lower(COALESCE(m.ZTEXT, '')), lower(?)) > 0
        AND (
          c.ZCONTACTJID LIKE '%@s.whatsapp.net' OR
          c.ZCONTACTJID LIKE '%@lid' OR
          (c.ZCONTACTJID LIKE '%@g.us' AND COALESCE(m.ZISFROMME, 0) = 0
           AND (gm.ZMEMBERJID LIKE '%@s.whatsapp.net' OR gm.ZMEMBERJID LIKE '%@lid'))
        )
      ORDER BY m.ZMESSAGEDATE DESC
    `).all(query);
    const contacts = contactDirectory(contactsPath);
    const normalized = rows.map((row) => {
      const contact = contacts.get(row.jid);
      const canonicalId = webChatId(contact?.phoneJid || row.jid);
      return {
        chatId: canonicalId, chatName: contact?.name || row.name || canonicalId,
        timestamp: Number(row.timestamp), body: row.body, fromGroup: Boolean(row.fromGroup),
      };
    });
    return {
      recipients: aggregateMatches(normalized), totalMessages: Number(totalMessages),
      matchMessages: normalized.length,
      groupAuthorMatches: normalized.filter((row) => row.fromGroup).length,
      dbPath,
    };
  } finally {
    db.close();
  }
}

module.exports = { DEFAULT_CHAT_STORAGE, DEFAULT_CONTACTS_STORAGE, searchNativeHistory, webChatId };

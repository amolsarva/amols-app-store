// ============================================================
// filestore.js  —  directory handle persistence + file writing
//
// FileSystemDirectoryHandle objects can only be stored in IndexedDB
// (not chrome.storage). We open a tiny IDB called "gve-filestore".
// ============================================================

const IDB_NAME = 'gve-filestore';
const IDB_VERSION = 1;
const STORE = 'handles';
const KEY = 'outputDir';

function openDB() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(IDB_NAME, IDB_VERSION);
    req.onupgradeneeded = (e) => e.target.result.createObjectStore(STORE);
    req.onsuccess = (e) => resolve(e.target.result);
    req.onerror = (e) => reject(e.target.error);
  });
}

export async function getSavedHandle() {
  const db = await openDB();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, 'readonly');
    const req = tx.objectStore(STORE).get(KEY);
    req.onsuccess = () => resolve(req.result ?? null);
    req.onerror = () => reject(req.error);
  });
}

export async function saveHandle(handle) {
  const db = await openDB();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, 'readwrite');
    const req = tx.objectStore(STORE).put(handle, KEY);
    req.onsuccess = () => resolve();
    req.onerror = () => reject(req.error);
  });
}

export async function clearHandle() {
  const db = await openDB();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, 'readwrite');
    const req = tx.objectStore(STORE).delete(KEY);
    req.onsuccess = () => resolve();
    req.onerror = () => reject(req.error);
  });
}

// Returns the stored handle if permission is still granted, else null.
export async function getVerifiedHandle() {
  const handle = await getSavedHandle();
  if (!handle) return null;
  try {
    const perm = await handle.queryPermission({ mode: 'readwrite' });
    if (perm === 'granted') return handle;
    // Try to re-request (only works if called from a user gesture)
    const req = await handle.requestPermission({ mode: 'readwrite' });
    return req === 'granted' ? handle : null;
  } catch {
    return null;
  }
}

// Prompt the user to pick a folder. Returns the handle.
export async function pickOutputFolder() {
  const handle = await window.showDirectoryPicker({
    id: 'gve-output',
    mode: 'readwrite',
    startIn: 'documents',
  });
  await saveHandle(handle);
  return handle;
}

// Get or prompt for folder. Call this before every export.
// mustPick=true forces a new picker even if a handle exists.
export async function requireOutputFolder(mustPick = false) {
  if (!mustPick) {
    const existing = await getVerifiedHandle();
    if (existing) return existing;
  }
  return pickOutputFolder();
}

// Write text content to <dir>/<subpath>, creating subdirectories as needed.
export async function writeTextFile(dirHandle, subpath, content, mime) {
  const parts = subpath.split('/').filter(Boolean);
  let current = dirHandle;
  for (const part of parts.slice(0, -1)) {
    current = await current.getDirectoryHandle(part, { create: true });
  }
  const filename = parts[parts.length - 1];
  const fileHandle = await current.getFileHandle(filename, { create: true });
  const writable = await fileHandle.createWritable();
  await writable.write(new Blob([content], { type: `${mime};charset=utf-8` }));
  await writable.close();
  return filename;
}

// Download an image URL into <dir>/images/<phoneSlug>/<filename>
// Uses fetch with credentials so Google's CDN URLs work.
export async function writeImageFile(dirHandle, phoneSlug, filename, url) {
  const resp = await fetch(url, { credentials: 'include' });
  if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
  const blob = await resp.blob();
  const imagesDir = await dirHandle.getDirectoryHandle('images', { create: true });
  const phoneDir = await imagesDir.getDirectoryHandle(phoneSlug || 'unknown', { create: true });
  const fileHandle = await phoneDir.getFileHandle(filename, { create: true });
  const writable = await fileHandle.createWritable();
  await writable.write(blob);
  await writable.close();
}

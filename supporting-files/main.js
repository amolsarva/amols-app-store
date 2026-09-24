const { app, BrowserWindow, ipcMain, shell } = require('electron');
const path = require('path');
const { spawn } = require('child_process');
const fs = require('fs');
const http = require('http');

// This file lives in mac-scripts/supporting-files/main.js — the actual tool
// folders (imessage-cleanup/, voicememocleaner/, etc.) are one level up, at
// the mac-scripts repo root. See AGENTS.md at that root for the full layout.
const SCRIPTS_DIR = path.join(__dirname, '..');
const PORT = 9741;

// ── script discovery ──────────────────────────────────────────────────────────

const ENTRY_POINTS = ['run.sh', 'main.py', 'run.py'];

// Folders under SCRIPTS_DIR that are infrastructure, not launchable tools.
const EXCLUDED_DIRS = new Set(['supporting-files', 'node_modules', '.git', '__pycache__']);

function findEntry(folder) {
  for (const ep of ENTRY_POINTS) {
    const p = path.join(folder, ep);
    if (fs.existsSync(p)) return p;
  }
  return folder; // fallback: open in Finder
}

function discover() {
  return fs.readdirSync(SCRIPTS_DIR)
    .filter(name => {
      if (name.startsWith('.')) return false;
      if (EXCLUDED_DIRS.has(name)) return false;
      const full = path.join(SCRIPTS_DIR, name);
      return fs.statSync(full).isDirectory();
    })
    .sort()
    .map(name => {
      const folder = path.join(SCRIPTS_DIR, name);
      const entry = findEntry(folder);
      return { name, entry, isDir: fs.statSync(entry).isDirectory() };
    });
}

// ── local API server ──────────────────────────────────────────────────────────

function startServer() {
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, `http://127.0.0.1:${PORT}`);
    res.setHeader('Access-Control-Allow-Origin', '*');

    if (url.pathname === '/api/scripts' && req.method === 'GET') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(discover()));

    } else if (url.pathname === '/api/launch' && req.method === 'POST') {
      let body = '';
      req.on('data', d => body += d);
      req.on('end', () => {
        const { name } = JSON.parse(body || '{}');
        const folder = path.join(SCRIPTS_DIR, name);
        if (!fs.existsSync(folder)) {
          res.writeHead(404); res.end('{}'); return;
        }
        const entry = findEntry(folder);
        const stat = fs.statSync(entry);
        if (stat.isDirectory()) {
          shell.openPath(entry);
        } else {
          const ext = path.extname(entry).toLowerCase();
          const cmd = ext === '.py' ? 'python3' : 'bash';
          spawn(ext === '.py' ? 'python3' : 'bash', [entry], {
            cwd: path.dirname(entry),
            detached: true, stdio: 'ignore'
          }).unref();
        }
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true, name }));
      });

    } else if (url.pathname === '/api/open-folder' && req.method === 'GET') {
      shell.openPath(SCRIPTS_DIR);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true }));

    } else {
      res.writeHead(404); res.end();
    }
  });

  server.listen(PORT, '127.0.0.1');
}

// ── window ────────────────────────────────────────────────────────────────────

function createWindow() {
  const win = new BrowserWindow({
    width: 680,
    height: 780,
    minWidth: 560,
    minHeight: 500,
    titleBarStyle: 'hiddenInset',   // native macOS traffic lights, no title bar chrome
    trafficLightPosition: { x: 18, y: 16 },
    backgroundColor: '#f2f2f7',
    vibrancy: 'under-window',       // frosted glass macOS effect
    visualEffectState: 'active',
    show: false,                     // show after load to avoid white flash
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
    }
  });

  // Remove the default menu bar
  win.setMenuBarVisibility(false);

  win.loadFile(path.join(__dirname, 'mac-scripts.html'));

  win.once('ready-to-show', () => win.show());

  // Open external links (GitHub etc.) in the system browser, not Electron
  win.webContents.setWindowOpenHandler(({ url }) => {
    shell.openExternal(url);
    return { action: 'deny' };
  });
  win.webContents.on('will-navigate', (e, url) => {
    if (!url.startsWith(`http://127.0.0.1:${PORT}`) && !url.startsWith('file://')) {
      e.preventDefault();
      shell.openExternal(url);
    }
  });
}

app.whenReady().then(() => {
  startServer();
  createWindow();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});

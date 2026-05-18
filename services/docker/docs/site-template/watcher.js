'use strict';
// Sidecar watcher - manages Docusaurus and exposes a tiny HTTP API.
//
// POST /<anything>/start  → begin file polling, start/restart Docusaurus
// POST /<anything>/stop   → stop file polling (Docusaurus keeps serving)
// GET  /<anything>/status → { watching: bool, restarting: bool }
//
// Env:
//   WATCH_DIRS  comma-separated paths to poll (default: /app/docs,/app/static)

const http = require('http');
const { spawn } = require('child_process');
const fs   = require('fs');
const path = require('path');

const WATCH_DIRS = (process.env.WATCH_DIRS || '/app/docs,/app/static')
  .split(',').map(s => s.trim()).filter(Boolean);
const POLL_MS = 1000;
const PORT    = 8080;

let watching   = false;
let restarting = true;   // true until Docusaurus responds to HTTP
let docProc    = null;
let pollTimer  = null;
let snapshot   = {};

// ── snapshot ──────────────────────────────────────────────────────────────

function walk(dir, out) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
  for (const e of entries) {
    const full = path.join(dir, e.name);
    if (e.isDirectory()) walk(full, out);
    else { try { out[full] = fs.statSync(full).mtimeMs; } catch { /* skip */ } }
  }
}

function snap() {
  const s = {};
  for (const d of WATCH_DIRS) walk(d, s);
  return s;
}

function changed(a, b) {
  const ka = Object.keys(a), kb = Object.keys(b);
  if (ka.length !== kb.length) return true;
  return ka.some(k => a[k] !== b[k]) || kb.some(k => !(k in a));
}

// ── Docusaurus lifecycle ──────────────────────────────────────────────────

function waitReady(cb) {
  const check = () => {
    const req = http.get('http://127.0.0.1:8000/', res => {
      if (res.statusCode < 500) { restarting = false; if (cb) cb(); }
      else setTimeout(check, 1000);
      res.resume();
    });
    req.on('error', () => setTimeout(check, 1000));
    req.end();
  };
  setTimeout(check, 3000);
}

function startDoc() {
  restarting = true;
  console.log('[watcher] starting Docusaurus');
  docProc = spawn(
    '/app/node_modules/.bin/docusaurus',
    ['start', '--host', '0.0.0.0', '--port', '8000'],
    { cwd: '/app', stdio: 'inherit' }
  );
  docProc.on('exit', (code, sig) => {
    docProc = null;
    if (sig !== 'SIGTERM') {
      console.log('[watcher] Docusaurus exited unexpectedly - restarting in 2s');
      setTimeout(startDoc, 2000);
    }
  });
  waitReady(() => console.log('[watcher] Docusaurus ready'));
}

function restartDoc() {
  console.log('[watcher] file change - restarting Docusaurus');
  if (docProc) {
    docProc.once('exit', () => { docProc = null; startDoc(); });
    docProc.kill('SIGTERM');
  } else {
    startDoc();
  }
}

// ── file watcher ──────────────────────────────────────────────────────────

function startWatching() {
  if (watching) return;
  snapshot = snap();
  watching = true;
  pollTimer = setInterval(() => {
    const cur = snap();
    if (changed(snapshot, cur)) { snapshot = cur; restartDoc(); }
  }, POLL_MS);
  console.log('[watcher] watching:', WATCH_DIRS.join(', '));
}

function stopWatching() {
  if (!watching) return;
  clearInterval(pollTimer);
  pollTimer = null;
  watching = false;
  console.log('[watcher] stopped watching');
}

// ── HTTP API ──────────────────────────────────────────────────────────────

const server = http.createServer((req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Content-Type', 'application/json');
  if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }

  const seg = req.url.split('/').filter(Boolean).pop();

  if (req.method === 'POST' && seg === 'start') {
    startWatching();
    res.writeHead(200);
    res.end(JSON.stringify({ ok: true, watching: true, restarting }));
    return;
  }
  if (req.method === 'POST' && seg === 'stop') {
    stopWatching();
    res.writeHead(200);
    res.end(JSON.stringify({ ok: true, watching: false, restarting }));
    return;
  }
  if (req.method === 'GET' && seg === 'status') {
    res.writeHead(200);
    res.end(JSON.stringify({ watching, restarting }));
    return;
  }

  res.writeHead(404);
  res.end(JSON.stringify({ error: 'not found' }));
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`[watcher] sidecar on :${PORT} | watching: ${WATCH_DIRS.join(', ')}`);
  startDoc();
});

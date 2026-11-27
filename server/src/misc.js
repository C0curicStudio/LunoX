'use strict';
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { config } = require('./config');
const { fetchBuffer } = require('./fetcher');

// ---------- tiny TTL cache ----------
class TTL {
  constructor(max, ttlMs) { this.m = new Map(); this.max = max; this.ttl = ttlMs; }
  get(k) { const v = this.m.get(k); if (!v) return undefined; if (v.e < Date.now()) { this.m.delete(k); return undefined; } return v.v; }
  set(k, v) { if (this.m.size >= this.max) this.m.delete(this.m.keys().next().value); this.m.set(k, { v, e: Date.now() + this.ttl }); }
}

// ---------- suggestions ----------
const SUGGEST = {
  google: (q) => `https://suggestqueries.google.com/complete/search?client=firefox&q=${encodeURIComponent(q)}`,
  bing: (q) => `https://api.bing.com/osjson.aspx?query=${encodeURIComponent(q)}`,
  duckduckgo: (q) => `https://duckduckgo.com/ac/?type=list&q=${encodeURIComponent(q)}`,
  baidu: (q) => `https://suggestion.baidu.com/su?action=opensearch&wd=${encodeURIComponent(q)}`,
};
const sugCache = new TTL(500, 5 * 60 * 1000);
async function suggest(q, engine = 'google') {
  q = String(q || '').slice(0, 100).trim();
  if (!q) return [];
  const mk = SUGGEST[engine] || SUGGEST.google;
  const ck = `${engine}:${q}`;
  const hit = sugCache.get(ck); if (hit) return hit;
  const r = await fetchBuffer(mk(q), {}, { maxBytes: 64 * 1024, timeoutMs: 4000 });
  let arr = [];
  try {
    const j = JSON.parse(r.body.toString('utf8'));
    arr = Array.isArray(j) ? (Array.isArray(j[1]) ? j[1] : j) : [];
  } catch { /* leave empty */ }
  arr = arr.filter((s) => typeof s === 'string').slice(0, 8);
  sugCache.set(ck, arr);
  return arr;
}

// ---------- favicon ----------
const favCache = new TTL(800, 24 * 3600 * 1000);
async function favicon(host) {
  if (!/^[a-z0-9.-]{1,253}$/i.test(host || '')) throw Object.assign(new Error('bad host'), { status: 400 });
  const hit = favCache.get(host); if (hit) return hit;
  let res;
  for (const u of [`https://${host}/favicon.ico`, `https://www.google.com/s2/favicons?domain=${host}&sz=64`]) {
    try {
      const r = await fetchBuffer(u, {}, { maxBytes: 128 * 1024, timeoutMs: 4000 });
      const ct = String(r.headers['content-type'] || '');
      if (r.status === 200 && r.body.length > 0 && /image|icon/.test(ct)) { res = { type: ct.split(';')[0], body: r.body }; break; }
    } catch { /* next */ }
  }
  if (!res) throw Object.assign(new Error('no icon'), { status: 404 });
  favCache.set(host, res);
  return res;
}

// Brave needs a custom header, so do it with https directly.
const https = require('node:https');
function getJson(url, headers) {
  return new Promise((resolve, reject) => {
    const req = https.get(url, { headers, timeout: 8000 }, (res) => {
      const chunks = []; let n = 0;
      res.on('data', (c) => { n += c.length; if (n > (1 << 20)) return req.destroy(new Error('too large')); chunks.push(c); });
      res.on('end', () => { try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8'))); } catch (e) { reject(e); } });
    });
    req.on('error', reject);
    req.on('timeout', () => req.destroy(new Error('timeout')));
  });
}
const strip = (h) => h.replace(/<[^>]+>/g, '').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#x27;|&#39;/g, "'").replace(/\s+/g, ' ').trim();
/** Parses DuckDuckGo's HTML results page (no API key needed). */
function parseDdg(html) {
  const out = [];
  const re = /<a[^>]+class="result__a"[^>]+href="([^"]+)"[^>]*>([\s\S]*?)<\/a>([\s\S]*?)(?=<a[^>]+class="result__a"|$)/g;
  let m;
  while ((m = re.exec(html)) && out.length < 8) {
    let href = m[1].replace(/&amp;/g, '&');
    const u = /[?&]uddg=([^&]+)/.exec(href);
    if (u) href = decodeURIComponent(u[1]);
    if (href.startsWith('//')) href = 'https:' + href;
    if (!/^https?:\/\//i.test(href)) continue;
    const sn = /class="result__snippet"[^>]*>([\s\S]*?)<\/a>/.exec(m[3]);
    out.push({ title: strip(m[2]), url: href, snippet: sn ? strip(sn[1]) : '' });
  }
  return out;
}
async function ddgSearch(q) {
  const r = await fetchBuffer(`https://html.duckduckgo.com/html/?q=${encodeURIComponent(q)}`, { 'accept-language': 'zh-CN,zh;q=0.9,en;q=0.8' }, { maxBytes: 1 << 20, timeoutMs: 8000 });
  return parseDdg(r.body.toString('utf8'));
}

async function webSearch(q) {
  const s = config.search;
  q = String(q || '').slice(0, 200).trim();
  if (!q) return [];
  if (s.provider === 'brave' && s.apiKey) {
    const j = await getJson(`https://api.search.brave.com/res/v1/web/search?count=8&q=${encodeURIComponent(q)}`, { 'x-subscription-token': s.apiKey, accept: 'application/json', 'accept-encoding': 'identity' });
    return ((j.web && j.web.results) || []).slice(0, 8).map((r) => ({ title: r.title, url: r.url, snippet: (r.description || '').replace(/<[^>]+>/g, '') }));
  }
  if (s.provider === 'ddg' || !s.provider) return ddgSearch(q);
  if (s.provider === 'searxng' && s.baseUrl) {
    const u = new URL('/search', s.baseUrl); u.searchParams.set('q', q); u.searchParams.set('format', 'json');
    const r = await fetchBuffer(u.toString(), {}, { maxBytes: 1 << 20, timeoutMs: 8000 });
    const j = JSON.parse(r.body.toString('utf8'));
    return (j.results || []).slice(0, 8).map((x) => ({ title: x.title, url: x.url, snippet: x.content || '' }));
  }
  throw Object.assign(new Error('search not configured'), { status: 501 });
}

// ---------- encrypted sync blobs (opaque to the server) ----------
const BUCKET = /^[a-z0-9_-]{1,32}$/;
function syncPath(keyHash, bucket) {
  if (!BUCKET.test(bucket)) throw Object.assign(new Error('bad bucket'), { status: 400 });
  return path.join(config.syncDir, keyHash, bucket);
}
function syncGet(keyHash, bucket) {
  try { return fs.readFileSync(syncPath(keyHash, bucket)); } catch { return null; }
}
function syncPut(keyHash, bucket, buf) {
  const p = syncPath(keyHash, bucket);
  fs.mkdirSync(path.dirname(p), { recursive: true, mode: 0o700 });
  const tmp = `${p}.${crypto.randomBytes(4).toString('hex')}.tmp`;
  fs.writeFileSync(tmp, buf, { mode: 0o600 });
  fs.renameSync(tmp, p);
}

module.exports = { suggest, favicon, webSearch, syncGet, syncPut, parseDdg };

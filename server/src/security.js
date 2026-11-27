'use strict';
const crypto = require('node:crypto');
const dns = require('node:dns');
const net = require('node:net');
const { config } = require('./config');

// ---------- SSRF guard ----------
const blocked = new net.BlockList();
[
  ['0.0.0.0', 8], ['10.0.0.0', 8], ['100.64.0.0', 10], ['127.0.0.0', 8], ['169.254.0.0', 16],
  ['172.16.0.0', 12], ['192.0.0.0', 24], ['192.168.0.0', 16], ['198.18.0.0', 15],
  ['224.0.0.0', 4], ['240.0.0.0', 4],
].forEach(([a, p]) => blocked.addSubnet(a, p, 'ipv4'));
[['::', 128], ['::1', 128], ['64:ff9b::', 96], ['fc00::', 7], ['fe80::', 10], ['ff00::', 8]]
  .forEach(([a, p]) => blocked.addSubnet(a, p, 'ipv6'));

function isBlockedIp(ip) {
  const v = net.isIP(ip);
  if (!v) return true;
  const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/i.exec(ip);
  if (mapped) return isBlockedIp(mapped[1]);
  if (/^::ffff:/i.test(ip)) return true; // hex-form mapped address: refuse
  return blocked.check(ip, v === 6 ? 'ipv6' : 'ipv4');
}

const SENSITIVE_PORTS = new Set([
  1433, 1521, 2049, 2375, 2376, 3306, 3389, 5432, 5900, 6379, 8086, 9042, 9200, 9300, 11211, 27017,
  ...config.extraBlockedPorts,
]);
function isPortAllowed(port) {
  if (!Number.isInteger(port) || port < 1 || port > 65535) return false;
  if (port === 80 || port === 443) return true;
  if (port < 1024) return false;
  return !SENSITIVE_PORTS.has(port);
}

/** dns.lookup replacement that refuses internal addresses (checked at connect time => no DNS rebinding). */
function safeLookup(hostname, options, cb) {
  if (typeof options === 'function') { cb = options; options = {}; }
  const opts = typeof options === 'number' ? { family: options } : { ...options };
  const wantAll = !!opts.all;
  opts.all = true;
  dns.lookup(hostname, opts, (err, addrs) => {
    if (err) return cb(err);
    const ok = addrs.filter((a) => !isBlockedIp(a.address));
    if (ok.length === 0 || ok.length !== addrs.length) {
      const e = new Error(`blocked destination: ${hostname}`);
      e.code = 'EBLOCKED';
      return cb(e);
    }
    if (wantAll) return cb(null, ok);
    return cb(null, ok[0].address, ok[0].family);
  });
}

/** IP literals skip dns.lookup entirely, so they must be checked up front. */
function assertPublicHost(host) {
  const h = String(host).replace(/^\[|\]$/g, '');
  if (net.isIP(h) && isBlockedIp(h)) {
    throw Object.assign(new Error('blocked destination'), { status: 403, code: 'EBLOCKED' });
  }
}

function parseHttpUrl(raw) {
  let u;
  try { u = new URL(raw); } catch { return null; }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
  if (u.username || u.password) return null;
  return u;
}

// ---------- Auth ----------
const keyHashes = config.apiKeys.map((k) => crypto.createHash('sha256').update(k).digest());
function checkKey(candidate) {
  if (!candidate || keyHashes.length === 0) return null;
  const h = crypto.createHash('sha256').update(candidate).digest();
  let found = null;
  keyHashes.forEach((kh, i) => { if (crypto.timingSafeEqual(kh, h)) found = i; }); // no early exit
  return found === null ? null : { id: String(found), hash: keyHashes[found].toString('hex').slice(0, 16) };
}
function bearerOf(req) {
  const m = /^Bearer\s+(\S+)$/i.exec(req.headers.authorization || '');
  return m ? m[1] : '';
}
function proxyPasswordOf(req) {
  const m = /^Basic\s+(\S+)$/i.exec(req.headers['proxy-authorization'] || '');
  if (!m) return '';
  const raw = Buffer.from(m[1], 'base64').toString('utf8');
  const i = raw.indexOf(':');
  return i < 0 ? '' : raw.slice(i + 1);
}

// ---------- Brute-force lockout & rate limit (in memory) ----------
const fails = new Map(); // ip -> {n, until, first}
function isBanned(ip) {
  const f = fails.get(ip);
  return !!f && f.until > Date.now();
}
function recordFail(ip) {
  const now = Date.now();
  const f = fails.get(ip) || { n: 0, until: 0, first: now };
  if (now - f.first > config.limits.authBanMs) { f.n = 0; f.first = now; }
  f.n += 1;
  if (f.n >= config.limits.authFailLimit) f.until = now + config.limits.authBanMs;
  fails.set(ip, f);
}
function recordOk(ip) { fails.delete(ip); }

const buckets = new Map(); // key -> {tokens, ts}
function allow(key, rps = config.limits.rps) {
  const now = Date.now();
  const b = buckets.get(key) || { tokens: rps * 2, ts: now };
  b.tokens = Math.min(rps * 2, b.tokens + ((now - b.ts) / 1000) * rps);
  b.ts = now;
  if (b.tokens < 1) { buckets.set(key, b); return false; }
  b.tokens -= 1;
  buckets.set(key, b);
  return true;
}
setInterval(() => {
  const now = Date.now();
  for (const [k, v] of fails) if (v.until < now && now - v.first > config.limits.authBanMs) fails.delete(k);
  for (const [k, v] of buckets) if (now - v.ts > 60000) buckets.delete(k);
}, 60000).unref();

function log(evt, data = {}) {
  process.stdout.write(JSON.stringify({ t: new Date().toISOString(), evt, ...data }) + '\n');
}

module.exports = {
  isBlockedIp, isPortAllowed, safeLookup, parseHttpUrl, assertPublicHost,
  checkKey, bearerOf, proxyPasswordOf, isBanned, recordFail, recordOk, allow, log,
};

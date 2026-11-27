'use strict';
const http = require('node:http');
const https = require('node:https');
const zlib = require('node:zlib');
const { pipeline } = require('node:stream');
const { config } = require('./config');
const { safeLookup, parseHttpUrl, isPortAllowed, assertPublicHost } = require('./security');

const UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';
const FORWARD = ['accept', 'accept-language', 'user-agent', 'referer', 'range', 'cookie'];

/** One upstream hop. Resolves with the raw IncomingMessage (not decoded). */
function hop(u, headers, timeoutMs) {
  return new Promise((resolve, reject) => {
    const lib = u.protocol === 'https:' ? https : http;
    const req = lib.request(u, { method: 'GET', headers, lookup: safeLookup, timeout: timeoutMs }, resolve);
    req.on('timeout', () => req.destroy(Object.assign(new Error('upstream timeout'), { code: 'ETIMEDOUT' })));
    req.on('error', reject);
    req.end();
  });
}

function decoder(enc) {
  switch ((enc || '').toLowerCase()) {
    case 'gzip': case 'x-gzip': return zlib.createGunzip();
    case 'br': return zlib.createBrotliDecompress();
    case 'deflate': return zlib.createInflate();
    default: return null;
  }
}

/**
 * Fetch `rawUrl` on behalf of a client. Manual redirects (re-validated each hop),
 * size cap, decoded body. Returns { status, finalUrl, headers, stream }.
 */
async function fetchUrl(rawUrl, clientHeaders = {}, { maxBytes = config.limits.maxFetchBytes, timeoutMs = 15000 } = {}) {
  let u = parseHttpUrl(rawUrl);
  if (!u) throw Object.assign(new Error('invalid url'), { status: 400 });
  const headers = { 'user-agent': UA, 'accept-encoding': 'gzip, br, deflate', accept: '*/*' };
  for (const k of FORWARD) if (clientHeaders[k]) headers[k] = String(clientHeaders[k]).slice(0, 2048);

  for (let i = 0; i <= 5; i++) {
    const port = u.port ? Number(u.port) : (u.protocol === 'https:' ? 443 : 80);
    if (!isPortAllowed(port)) throw Object.assign(new Error('port not allowed'), { status: 403 });
    assertPublicHost(u.hostname);
    const res = await hop(u, { ...headers, host: u.host }, timeoutMs);
    if ([301, 302, 303, 307, 308].includes(res.statusCode) && res.headers.location) {
      res.resume();
      const next = parseHttpUrl(new URL(res.headers.location, u).toString());
      if (!next) throw Object.assign(new Error('bad redirect'), { status: 502 });
      u = next;
      if (i === 5) throw Object.assign(new Error('too many redirects'), { status: 508 });
      continue;
    }
    const dec = decoder(res.headers['content-encoding']);
    let seen = 0;
    const { Transform } = require('node:stream');
    const cap = new Transform({
      transform(chunk, _e, cb) {
        seen += chunk.length;
        if (seen > maxBytes) return cb(Object.assign(new Error('response too large'), { code: 'ETOOBIG' }));
        cb(null, chunk);
      },
    });
    const out = dec ? pipeline(res, dec, cap, () => {}) : pipeline(res, cap, () => {});
    const h = { ...res.headers };
    for (const k of ['content-encoding', 'content-length', 'transfer-encoding', 'set-cookie', 'connection', 'keep-alive']) delete h[k];
    return { status: res.statusCode, finalUrl: u.toString(), headers: h, stream: out };
  }
  throw new Error('unreachable');
}

async function fetchBuffer(rawUrl, headers, opts) {
  const r = await fetchUrl(rawUrl, headers, opts);
  const chunks = [];
  for await (const c of r.stream) chunks.push(c);
  return { ...r, body: Buffer.concat(chunks) };
}

module.exports = { fetchUrl, fetchBuffer };

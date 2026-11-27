'use strict';
/**
 * WebSocket tunnel: lets clients reach the gateway through Cloudflare's edge (CF forwards WebSocket but not
 * HTTP CONNECT). Zero dependencies: minimal RFC 6455 server framing.
 *
 *   GET /v1/tunnel?host=example.com&port=443   Upgrade: websocket   Authorization: Bearer <key>
 *   <- first text frame "ok" (or "err:<reason>" then close)
 *   <-> binary frames carry raw TCP bytes
 */
const crypto = require('node:crypto');
const net = require('node:net');
const { config } = require('./config');
const sec = require('./security');

const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
const MAX_FRAME = 1 << 20;

function frame(opcode, payload) {
  const n = payload.length;
  let h;
  if (n < 126) h = Buffer.from([0x80 | opcode, n]);
  else if (n < 65536) { h = Buffer.alloc(4); h[0] = 0x80 | opcode; h[1] = 126; h.writeUInt16BE(n, 2); }
  else { h = Buffer.alloc(10); h[0] = 0x80 | opcode; h[1] = 127; h.writeBigUInt64BE(BigInt(n), 2); }
  return Buffer.concat([h, payload]);
}

/** Incremental parser for client->server (masked) frames. */
class Parser {
  constructor(onFrame, onError) { this.buf = Buffer.alloc(0); this.onFrame = onFrame; this.onError = onError; this.cont = null; }
  push(chunk) {
    this.buf = Buffer.concat([this.buf, chunk]);
    for (;;) {
      const b = this.buf;
      if (b.length < 2) return;
      const fin = !!(b[0] & 0x80), op = b[0] & 0x0f, masked = !!(b[1] & 0x80);
      let len = b[1] & 0x7f, off = 2;
      if (!masked) return this.onError('unmasked frame');
      if (len === 126) { if (b.length < 4) return; len = b.readUInt16BE(2); off = 4; }
      else if (len === 127) { if (b.length < 10) return; const big = b.readBigUInt64BE(2); if (big > BigInt(MAX_FRAME)) return this.onError('frame too large'); len = Number(big); off = 10; }
      if (len > MAX_FRAME) return this.onError('frame too large');
      if (b.length < off + 4 + len) return;
      const mask = b.subarray(off, off + 4);
      const data = Buffer.from(b.subarray(off + 4, off + 4 + len));
      for (let i = 0; i < data.length; i++) data[i] ^= mask[i & 3];
      this.buf = b.subarray(off + 4 + len);
      if (op === 0 && this.cont) { this.cont.data.push(data); if (fin) { const full = Buffer.concat(this.cont.data); const o = this.cont.op; this.cont = null; this.onFrame(o, full); } continue; }
      if (!fin && (op === 1 || op === 2)) { this.cont = { op, data: [data] }; continue; }
      this.onFrame(op, data);
    }
  }
}

let active = 0;

function handleUpgrade(req, socket, head) {
  const ip = sec.clientIp(req);
  socket.on('error', () => {});
  const refuse = (code, msg) => socket.end(`HTTP/1.1 ${code} ${msg}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);

  // Behind Cloudflare the client IP is in CF-Connecting-IP; only trust it when the TCP peer is a CF address
  // would need a range list, so we deliberately key bans on the socket peer only.
  if (sec.isBanned(ip)) return socket.destroy();
  const url = new URL(req.url, 'https://x');
  if (url.pathname !== '/v1/tunnel' || String(req.headers.upgrade || '').toLowerCase() !== 'websocket') return refuse(404, 'Not Found');
  const key = sec.checkKey(sec.bearerOf(req) || url.searchParams.get('k') || '');
  if (!key) { sec.recordFail(ip); sec.log('ws_auth_fail', { ip }); return refuse(401, 'Unauthorized'); }
  sec.recordOk(ip);
  const wsKey = req.headers['sec-websocket-key'];
  if (!wsKey || !sec.allow(`ws:${key.id}`, 10)) return refuse(wsKey ? 429 : 400, 'Bad Request');

  // Warm mode: no host/port in the URL. The socket is opened early (saving the TLS+upgrade round trips on the
  // user's critical path) and the target arrives later as the first text frame {"host":..,"port":..}.
  const qHost = url.searchParams.get('host');
  const warm = qHost === null;
  if (active >= config.limits.maxTunnels) return refuse(503, 'Busy');
  if (!warm && !validTarget(qHost, Number(url.searchParams.get('port')))) return refuse(403, 'Forbidden');

  const accept = crypto.createHash('sha1').update(wsKey + GUID).digest('base64');
  socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
  socket.setNoDelay(true);

  active++;
  let up = 0, down = 0, closed = false, upstream = null, target = { host: qHost, port: Number(url.searchParams.get('port')) };
  const finish = (why) => {
    if (closed) return; closed = true; active--;
    try { socket.write(frame(8, Buffer.alloc(0))); } catch { /* ignore */ }
    socket.destroy(); if (upstream) upstream.destroy();
    if (upstream) sec.log('ws_tunnel', { key: key.hash, ip, host: target.host, port: target.port, up, down, why });
  };

  function startUpstream(host, port) {
    target = { host, port };
    upstream = net.connect({ host, port, lookup: sec.safeLookup, timeout: 10000 });
    upstream.setNoDelay(true);
    upstream.once('connect', () => {
      upstream.setTimeout(config.limits.tunnelIdleMs);
      socket.setTimeout(config.limits.tunnelIdleMs);
      socket.write(frame(1, Buffer.from('ok')));
      upstream.on('data', (d) => {
        down += d.length;
        for (let i = 0; i < d.length; i += 65536) if (!socket.write(frame(2, d.subarray(i, i + 65536)))) { upstream.pause(); socket.once('drain', () => upstream.resume()); break; }
      });
    });
    upstream.on('error', (e) => {
      if (upstream.connecting) { try { socket.write(frame(1, Buffer.from(`err:${e.code === 'EBLOCKED' ? 'blocked' : 'connect'}`))); } catch { /* ignore */ } }
      finish('upstream-error');
    });
    upstream.on('timeout', () => finish('idle'));
    upstream.on('end', () => finish('upstream-end'));
  }

  const parser = new Parser((op, data) => {
    if (op === 1 && !upstream) {                       // warm socket receives its target
      let t; try { t = JSON.parse(data.toString('utf8')); } catch { return finish('bad-target'); }
      if (!t || typeof t.host !== 'string' || !validTarget(t.host, Number(t.port))) {
        try { socket.write(frame(1, Buffer.from('err:blocked'))); } catch { /* ignore */ }
        return finish('refused');
      }
      return startUpstream(t.host, Number(t.port));
    }
    if (op === 2 || op === 1) { if (upstream && upstream.writable) { up += data.length; if (!upstream.write(data)) { socket.pause(); upstream.once('drain', () => socket.resume()); } } }
    else if (op === 8) finish('client-close');
    else if (op === 9) socket.write(frame(10, data));
  }, (m) => finish(m));

  socket.setTimeout(warm ? 90000 : config.limits.tunnelIdleMs, () => finish(upstream ? 'idle' : 'warm-expired'));
  socket.on('data', (d) => parser.push(d));
  socket.on('close', () => finish('client-gone'));
  if (!warm) startUpstream(target.host, target.port);
  if (head && head.length) parser.push(head);
}

function validTarget(host, port) {
  if (!/^[A-Za-z0-9.\-:]{1,253}$/.test(host) || !sec.isPortAllowed(port)) return false;
  try { sec.assertPublicHost(host); return true; } catch { return false; }
}

module.exports = { handleUpgrade, frame, Parser };

'use strict';
const net = require('node:net');
const { config } = require('./config');
const sec = require('./security');

let active = 0;
const perIp = new Map();

function parseTarget(s) {
  const m = /^\[([^\]]+)\]:(\d+)$/.exec(s) || /^([^:\s]+):(\d+)$/.exec(s);
  if (!m) return null;
  return { host: m[1], port: Number(m[2]) };
}

function deny(sock, line, extra = '') {
  sock.end(`HTTP/1.1 ${line}\r\n${extra}Connection: close\r\nContent-Length: 0\r\n\r\n`);
}

/** HTTPS CONNECT proxy. Mounted on the TLS server's 'connect' event. */
function handleConnect(req, client, head) {
  const ip = (client.remoteAddress || '').replace(/^::ffff:/, '');
  client.on('error', () => {});

  if (sec.isBanned(ip)) return client.destroy();
  const key = sec.checkKey(sec.proxyPasswordOf(req));
  if (!key) {
    sec.recordFail(ip);
    sec.log('proxy_auth_fail', { ip });
    return deny(client, '407 Proxy Authentication Required', 'Proxy-Authenticate: Basic realm="lunox"\r\n');
  }
  sec.recordOk(ip);

  const target = parseTarget(req.url || '');
  if (!target || !sec.isPortAllowed(target.port)) return deny(client, '403 Forbidden');
  try { sec.assertPublicHost(target.host); } catch { return deny(client, '403 Forbidden'); }
  if ((perIp.get(ip) || 0) >= config.limits.maxTunnelsPerIp || active >= config.limits.maxTunnels) {
    return deny(client, '429 Too Many Requests');
  }

  active++; perIp.set(ip, (perIp.get(ip) || 0) + 1);
  let up = 0, down = 0, done = false;
  const finish = () => {
    if (done) return; done = true;
    active--; perIp.set(ip, Math.max(0, (perIp.get(ip) || 1) - 1));
    sec.log('tunnel', { key: key.hash, ip, host: target.host, port: target.port, up, down });
  };

  const upstream = net.connect({ host: target.host, port: target.port, lookup: sec.safeLookup, timeout: 10000 });
  upstream.setNoDelay(true);
  upstream.once('connect', () => {
    upstream.setTimeout(config.limits.tunnelIdleMs);
    client.setTimeout(config.limits.tunnelIdleMs);
    client.write('HTTP/1.1 200 Connection Established\r\n\r\n');
    if (head && head.length) upstream.write(head);
    client.on('data', (d) => { up += d.length; });
    upstream.on('data', (d) => { down += d.length; });
    client.pipe(upstream);
    upstream.pipe(client);
  });
  const kill = () => { client.destroy(); upstream.destroy(); finish(); };
  upstream.on('error', (e) => {
    if (!upstream.connecting) return kill();
    deny(client, e.code === 'EBLOCKED' ? '403 Forbidden' : '502 Bad Gateway');
    upstream.destroy(); finish();
  });
  upstream.on('timeout', kill);
  client.on('timeout', kill);
  client.on('close', kill);
  upstream.on('close', kill);
}

module.exports = { handleConnect, parseTarget, stats: () => ({ active }) };

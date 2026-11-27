'use strict';
const https = require('node:https');
const fs = require('node:fs');
const { config } = require('./config');
const sec = require('./security');
const { fetchUrl } = require('./fetcher');
const { handleConnect, stats } = require('./proxy');
const llm = require('./llm');
const misc = require('./misc');

const SEC_HEADERS = {
  'x-content-type-options': 'nosniff',
  'cache-control': 'no-store',
  'referrer-policy': 'no-referrer',
  'strict-transport-security': 'max-age=31536000',
  'content-security-policy': "default-src 'none'",
};

function send(res, status, obj) {
  const body = Buffer.from(JSON.stringify(obj));
  res.writeHead(status, { ...SEC_HEADERS, 'content-type': 'application/json; charset=utf-8', 'content-length': body.length });
  res.end(body);
}

function readBody(req, max) {
  return new Promise((resolve, reject) => {
    const chunks = []; let n = 0;
    req.on('data', (c) => { n += c.length; if (n > max) { reject(Object.assign(new Error('body too large'), { status: 413 })); req.destroy(); } else chunks.push(c); });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}
const readJson = async (req) => {
  try { return JSON.parse((await readBody(req, config.limits.maxBodyBytes)).toString('utf8') || '{}'); }
  catch (e) { throw e.status ? e : Object.assign(new Error('bad json'), { status: 400 }); }
};

async function route(req, res) {
  const ip = (req.socket.remoteAddress || '').replace(/^::ffff:/, '');
  const url = new URL(req.url, 'https://x');
  const p = url.pathname;

  if (sec.isBanned(ip)) return send(res, 429, { error: 'banned' });
  const key = sec.checkKey(sec.bearerOf(req));
  if (!key) {
    sec.recordFail(ip);
    return send(res, 401, { error: 'unauthorized' }); // identical body for every failure
  }
  sec.recordOk(ip);
  if (!sec.allow(key.id)) return send(res, 429, { error: 'rate limited' });

  if (req.method === 'GET' && p === '/v1/health') {
    return send(res, 200, { ok: true, v: 1, now: Date.now(), tunnels: stats().active, llm: !!config.llm.apiKey, search: !!config.search.provider });
  }

  if (req.method === 'GET' && p === '/v1/fetch') {
    const target = url.searchParams.get('url') || '';
    const r = await fetchUrl(target, req.headers, { maxBytes: Math.min(config.limits.maxFetchBytes, Number(url.searchParams.get('max')) || Infinity) });
    const h = { ...SEC_HEADERS, 'x-lunox-status': String(r.status), 'x-lunox-final-url': encodeURI(r.finalUrl) };
    if (r.headers['content-type']) h['content-type'] = r.headers['content-type'];
    res.writeHead(200, h);
    r.stream.on('error', () => res.destroy());
    r.stream.pipe(res);
    return undefined;
  }

  if (req.method === 'GET' && p === '/v1/suggest') {
    return send(res, 200, { items: await misc.suggest(url.searchParams.get('q'), url.searchParams.get('engine') || 'google').catch(() => []) });
  }

  if (req.method === 'GET' && p === '/v1/favicon') {
    const f = await misc.favicon(url.searchParams.get('host'));
    res.writeHead(200, { ...SEC_HEADERS, 'cache-control': 'private, max-age=86400', 'content-type': f.type, 'content-length': f.body.length });
    return res.end(f.body);
  }

  if (req.method === 'GET' && p === '/v1/search') {
    return send(res, 200, { results: await misc.webSearch(url.searchParams.get('q')) });
  }

  if (req.method === 'POST' && (p === '/v1/ai' || p === '/v1/ai/stream')) {
    const body = await readJson(req);
    const args = body.args || {};
    for (const k of ['text', 'results']) if (typeof args[k] === 'string') args[k] = args[k].slice(0, 60000);
    for (const k of ['question', 'goal']) if (typeof args[k] === 'string') args[k] = args[k].slice(0, 2000);
    if (body.task === 'search_answer' && !args.results) {
      const rs = await misc.webSearch(args.question);
      args.results = rs.map((r, i) => `[${i + 1}] ${r.title}\n${r.url}\n${r.snippet}`).join('\n\n');
      res.setHeader('x-lunox-sources', Buffer.from(JSON.stringify(rs)).toString('base64'));
    }
    const streaming = p === '/v1/ai/stream';
    if (streaming) {
      res.writeHead(200, { ...SEC_HEADERS, 'content-type': 'text/event-stream; charset=utf-8', ...(res.getHeader('x-lunox-sources') ? { 'x-lunox-sources': res.getHeader('x-lunox-sources') } : {}) });
      try {
        await llm.run({ task: body.task, args, messages: body.messages }, (t) => res.write(`data: ${JSON.stringify({ t })}\n\n`));
        res.write('data: [DONE]\n\n');
      } catch (e) { res.write(`data: ${JSON.stringify({ error: e.message })}\n\n`); }
      return res.end();
    }
    let text = '';
    await llm.run({ task: body.task, args, messages: body.messages }, (t) => { text += t; });
    if (body.task === 'act') return send(res, 200, { plan: llm.parseActions(text) });
    return send(res, 200, { text });
  }

  const m = /^\/v1\/sync\/([a-z0-9_-]{1,32})$/.exec(p);
  if (m && req.method === 'GET') {
    const b = misc.syncGet(key.hash, m[1]);
    if (!b) return send(res, 404, { error: 'not found' });
    res.writeHead(200, { ...SEC_HEADERS, 'content-type': 'application/octet-stream', 'content-length': b.length });
    return res.end(b);
  }
  if (m && req.method === 'PUT') {
    const b = await readBody(req, 4 * 1024 * 1024);
    misc.syncPut(key.hash, m[1], b);
    return send(res, 200, { ok: true });
  }

  return send(res, 404, { error: 'not found' });
}

function createServer() {
  const srv = https.createServer({
    cert: fs.readFileSync(config.tlsCert),
    key: fs.readFileSync(config.tlsKey),
    minVersion: 'TLSv1.2',
    requestTimeout: 120000,
    headersTimeout: 15000,
  }, (req, res) => {
    route(req, res).catch((e) => {
      sec.log('error', { path: req.url.split('?')[0], msg: e.message });
      if (res.headersSent) return res.destroy();
      send(res, e.status || (e.code === 'EBLOCKED' ? 403 : 502), { error: e.status ? e.message : 'upstream error' });
    });
  });
  srv.on('connect', handleConnect);
  srv.on('clientError', (_e, s) => s.destroy());
  return srv;
}

if (require.main === module) {
  if (config.apiKeys.length === 0 || config.apiKeys.some((k) => k.length < 24)) {
    console.error('LUNOX_API_KEYS must contain at least one key of >= 24 chars'); process.exit(1);
  }
  createServer().listen(config.port, config.bind, () => sec.log('listening', { port: config.port }));
  process.on('uncaughtException', (e) => sec.log('uncaught', { msg: e.message }));
  process.on('unhandledRejection', (e) => sec.log('unhandled', { msg: String(e && e.message) }));
}

module.exports = { createServer };

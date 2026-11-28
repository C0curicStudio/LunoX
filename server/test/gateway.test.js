'use strict';
process.env.LUNOX_API_KEYS = 'test-key-test-key-test-key-1234';
const test = require('node:test');
const assert = require('node:assert');
const sec = require('../src/security');
const { parseTarget } = require('../src/proxy');
const { parseActions } = require('../src/llm');

test('blocks internal IPs, allows public', () => {
  for (const ip of ['127.0.0.1', '10.1.2.3', '192.168.1.1', '169.254.169.254', '172.20.0.1', '::1', 'fe80::1', '::ffff:127.0.0.1', 'fd00::1', '100.64.0.1'])
    assert.ok(sec.isBlockedIp(ip), ip);
  for (const ip of ['8.8.8.8', '1.1.1.1', '2606:4700:4700::1111']) assert.ok(!sec.isBlockedIp(ip), ip);
});

test('port policy', () => {
  assert.ok(sec.isPortAllowed(443) && sec.isPortAllowed(80) && sec.isPortAllowed(8080));
  assert.ok(!sec.isPortAllowed(22) && !sec.isPortAllowed(25) && !sec.isPortAllowed(6379) && !sec.isPortAllowed(0));
});

test('only http(s) urls without credentials', () => {
  assert.ok(sec.parseHttpUrl('https://example.com/x'));
  for (const u of ['file:///etc/passwd', 'ftp://a.com', 'javascript:alert(1)', 'https://u:p@a.com', 'nope']) assert.equal(sec.parseHttpUrl(u), null, u);
});

test('safeLookup refuses localhost', (t, done) => {
  sec.safeLookup('localhost', {}, (err) => { assert.equal(err && err.code, 'EBLOCKED'); done(); });
});

test('key check is exact', () => {
  assert.ok(sec.checkKey('test-key-test-key-test-key-1234'));
  assert.equal(sec.checkKey('test-key-test-key-test-key-1235'), null);
  assert.equal(sec.checkKey(''), null);
});

test('lockout after repeated failures', () => {
  const ip = '203.0.113.9';
  for (let i = 0; i < 8; i++) sec.recordFail(ip);
  assert.ok(sec.isBanned(ip));
});

test('CONNECT target parsing', () => {
  assert.deepEqual(parseTarget('example.com:443'), { host: 'example.com', port: 443 });
  assert.deepEqual(parseTarget('[2001:db8::1]:443'), { host: '2001:db8::1', port: 443 });
  assert.equal(parseTarget('bad'), null);
});

test('AI action plans are sanitised', () => {
  const p = parseActions('x {"thought":"t","done":false,"actions":[{"type":"click","id":3},{"type":"goto","url":"javascript:alert(1)"},{"type":"rm","id":1},{"type":"type","id":2,"text":"hi"}]} y');
  assert.deepEqual(p.actions.map((a) => a.type), ['click', 'type']);
});

test('IP literals are refused before connecting', () => {
  assert.throws(() => sec.assertPublicHost('127.0.0.1'), /blocked/);
  assert.throws(() => sec.assertPublicHost('[::1]'), /blocked/);
  assert.throws(() => sec.assertPublicHost('169.254.169.254'), /blocked/);
  assert.doesNotThrow(() => sec.assertPublicHost('example.com'));
  assert.doesNotThrow(() => sec.assertPublicHost('8.8.8.8'));
});

test('DuckDuckGo result parser', () => {
  const { parseDdg } = require('../src/misc');
  const html = `<div class="result"><a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa%3Fx%3D1&amp;rut=abc">Example &amp; <b>Co</b></a>
    <a class="result__snippet" href="x">A <b>great</b> site</a></div>
    <div class="result"><a class="result__a" href="https://b.org/">B</a><a class="result__snippet">snip B</a></div>`;
  const r = parseDdg(html);
  assert.equal(r.length, 2);
  assert.deepEqual(r[0], { title: 'Example & Co', url: 'https://example.com/a?x=1', snippet: 'A great site' });
  assert.equal(r[1].url, 'https://b.org/');
});

test('client ip is taken from CF-Connecting-IP only for loopback peers', () => {
  const mk = (addr, h) => ({ socket: { remoteAddress: addr }, headers: h });
  assert.equal(sec.clientIp(mk('127.0.0.1', { 'cf-connecting-ip': '9.9.9.9' })), '9.9.9.9');
  assert.equal(sec.clientIp(mk('8.8.8.8', { 'cf-connecting-ip': '9.9.9.9' })), '8.8.8.8');
});

test('RSS/Atom/YouTube feed parsing', () => {
  const { parseFeed } = require('../src/news');
  const rss = `<rss><channel><item><title><![CDATA[Big &amp; bold]]></title><link>https://ex.com/a</link><pubDate>Fri, 28 Nov 2026 10:00:00 GMT</pubDate>
    <description><![CDATA[<p>Hello <b>world</b></p>]]></description><media:thumbnail url="https://ichef.bbci.co.uk/news/240/cpsprodpb/x.jpg" width="240"/>
    <media:thumbnail url="https://ichef.bbci.co.uk/news/976/cpsprodpb/x.jpg" width="976"/></item></channel></rss>`;
  const [a] = parseFeed(rss, 'T');
  assert.equal(a.title, 'Big & bold'); assert.equal(a.summary, 'Hello world'); assert.equal(a.url, 'https://ex.com/a');
  assert.ok(a.image.includes('976')); assert.ok(a.ts > 0);
  const yt = `<feed><entry><title>Clip</title><link rel="alternate" href="https://www.youtube.com/watch?v=abcdefghijk"/><yt:videoId>abcdefghijk</yt:videoId><published>2026-11-28T09:00:00+00:00</published></entry></feed>`;
  const [v] = parseFeed(yt, 'Y');
  assert.deepEqual(v.video, { kind: 'youtube', id: 'abcdefghijk' }); assert.ok(v.image.includes('abcdefghijk'));
  assert.deepEqual(parseFeed('<rss><item><title>x</title><link>javascript:alert(1)</link></item></rss>', 'Z'), []);
});

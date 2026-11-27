#!/usr/bin/env node
// Puts the LunoX gateway behind Cloudflare's edge (no dependencies, Node >= 18).
//
//   CF_API_TOKEN=xxxx node cloudflare/setup.mjs --zone example.com [--name edge] [--ip 186.244.245.83] [--dry-run]
//
// What it does (nothing else is touched):
//   1. finds your zone
//   2. creates/updates   edge.<zone>  A  <server ip>   (proxied = orange cloud)  -> clients enter Cloudflare's nearest edge
//   3. zone settings: SSL mode "full" (origin keeps its self-signed cert), WebSockets on, HTTP/3 on
//
// Token permissions needed: Zone:Read, DNS:Edit, Zone Settings:Edit (for that zone only).
// The token is read from the environment and never written anywhere.

const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf(`--${k}`); return i >= 0 ? args[i + 1] : d; };
const dry = args.includes('--dry-run');
const zoneName = opt('zone', process.env.CF_ZONE);
const sub = opt('name', 'edge');
const ip = opt('ip', '186.244.245.83');
const token = process.env.CF_API_TOKEN;

if (!zoneName) { console.error('usage: CF_API_TOKEN=... node setup.mjs --zone example.com [--name edge] [--ip 1.2.3.4] [--dry-run]'); process.exit(1); }
if (!token && !dry) { console.error('CF_API_TOKEN is not set'); process.exit(1); }

const host = `${sub}.${zoneName}`;
const API = 'https://api.cloudflare.com/client/v4';

async function cf(method, path, body) {
  if (dry) { console.log(`[dry-run] ${method} ${path}${body ? ' ' + JSON.stringify(body) : ''}`); return { result: [{ id: 'ZONE_ID' }] }; }
  const r = await fetch(API + path, { method, headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, body: body ? JSON.stringify(body) : undefined });
  const j = await r.json().catch(() => ({}));
  if (!j.success) throw new Error(`${method} ${path} -> ${r.status} ${JSON.stringify(j.errors || j)}`);
  return j;
}

const zones = await cf('GET', `/zones?name=${encodeURIComponent(zoneName)}`);
if (!zones.result.length) { console.error(`zone ${zoneName} not found for this token`); process.exit(1); }
const zid = zones.result[0].id;
console.log(`zone ${zoneName}: ${zid}`);

// 2. DNS
const recs = await cf('GET', `/zones/${zid}/dns_records?name=${encodeURIComponent(host)}`);
const want = { type: 'A', name: host, content: ip, proxied: true, ttl: 1, comment: 'LunoX gateway (managed by setup.mjs)' };
const existing = recs.result.find((r) => r.type === 'A' || r.type === 'AAAA' || r.type === 'CNAME');
if (existing && existing.type !== 'A') { console.error(`${host} already exists as ${existing.type}; pick another --name`); process.exit(1); }
if (existing) { await cf('PUT', `/zones/${zid}/dns_records/${existing.id}`, want); console.log(`updated  ${host} -> ${ip} (proxied)`); }
else { await cf('POST', `/zones/${zid}/dns_records`, want); console.log(`created  ${host} -> ${ip} (proxied)`); }

// 3. zone settings
for (const [id, value] of [['ssl', 'full'], ['websockets', 'on'], ['http3', 'on'], ['min_tls_version', '1.2']]) {
  try { await cf('PATCH', `/zones/${zid}/settings/${id}`, { value }); console.log(`setting  ${id} = ${value}`); }
  catch (e) { console.warn(`! could not set ${id}: ${e.message}`); }
}

console.log(`
Done. Cloudflare edge host: ${host}
- The gateway must listen on a port Cloudflare proxies. 8443 is one of them (443, 2053, 2083, 2087, 2096, 8443).
- In the app: Settings > Network > Edge host = ${host}  (or add  &edge=${host}  to the lunox://setup link).
- Check from anywhere:  curl -sI https://${host}:8443/v1/health | grep -i cf-ray   (suffix = the edge city, e.g. -HKG)`);

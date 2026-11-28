'use strict';
/**
 * News aggregator: public RSS/Atom feeds (+ YouTube channel feeds for video, ESPN scoreboards, Google Trends),
 * fetched from the server's network so the phone never needs direct access to them. Zero dependencies.
 *   GET /v1/news?cat=explore|world|china|tech|finance|sports|entertainment|science|french|video
 *   GET /v1/news/scores        GET /v1/news/trends?geo=US
 */
const crypto = require('node:crypto');
const { fetchBuffer, fetchUrl } = require('./fetcher');

const YT = (id) => `https://www.youtube.com/feeds/videos.xml?channel_id=${id}`;
const FEEDS = {
  world: [['BBC News', 'https://feeds.bbci.co.uk/news/world/rss.xml'], ['The Guardian', 'https://www.theguardian.com/world/rss'], ['NPR', 'https://feeds.npr.org/1001/rss.xml'], ['Al Jazeera', 'https://www.aljazeera.com/xml/rss/all.xml']],
  china: [['BBC 中文', 'https://feeds.bbci.co.uk/zhongwen/simp/rss.xml'], ['中新网', 'https://www.chinanews.com.cn/rss/scroll-news.xml'], ['少数派', 'https://sspai.com/feed'], ['FT 中文网', 'https://www.ftchinese.com/rss/news']],
  tech: [['The Verge', 'https://www.theverge.com/rss/index.xml'], ['Ars Technica', 'https://feeds.arstechnica.com/arstechnica/index'], ['TechCrunch', 'https://techcrunch.com/feed/'], ['36氪', 'https://36kr.com/feed']],
  finance: [['BBC Business', 'https://feeds.bbci.co.uk/news/business/rss.xml'], ['CNBC', 'https://www.cnbc.com/id/100003114/device/rss/rss.html'], ['Guardian Business', 'https://www.theguardian.com/uk/business/rss']],
  sports: [['BBC Sport', 'https://feeds.bbci.co.uk/sport/rss.xml'], ['ESPN', 'https://www.espn.com/espn/rss/news'], ['Guardian Sport', 'https://www.theguardian.com/sport/rss']],
  entertainment: [['BBC Entertainment', 'https://feeds.bbci.co.uk/news/entertainment_and_arts/rss.xml'], ['Variety', 'https://variety.com/feed/'], ['Guardian Film', 'https://www.theguardian.com/film/rss']],
  science: [['NASA', 'https://www.nasa.gov/feed/'], ['BBC Science', 'https://feeds.bbci.co.uk/news/science_and_environment/rss.xml'], ['Nature', 'https://www.nature.com/nature.rss']],
  french: [['Le Monde', 'https://www.lemonde.fr/rss/une.xml'], ['France 24', 'https://www.france24.com/fr/rss'], ['RFI', 'https://www.rfi.fr/fr/rss']],
  video: [['BBC News', YT('UC16niRr50-MSBwiO3YDb3RA')], ['Reuters', YT('UChqUTb7kYRX8-EiaN3XFrSQ')], ['NASA', YT('UCLA_DiR1FfKNvjuUpBHmylQ')], ['DW News', YT('UCknLrEdhRCp1aegoMqRaCZg')], ['Al Jazeera', YT('UCNye-wNBqNL5ZzHSJj3l8Bg')], ['CNN', YT('UCupvZG-5ko_eiXAupbDfxWw')], ['Bloomberg', YT('UCIALMKvObZNtJ6AmdCLP7Lg')]],
};
const CATS = Object.keys(FEEDS);

// ---------- tiny XML helpers ----------
const ENT = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ' };
const decode = (s) => s.replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, '$1')
  .replace(/&(#x?[0-9a-f]+|[a-z]+);/gi, (m, e) => {
    if (e[0] === '#') { const n = e[1].toLowerCase() === 'x' ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10); return Number.isFinite(n) && n > 0 && n < 0x110000 ? String.fromCodePoint(n) : m; }
    return ENT[e.toLowerCase()] ?? m;
  });
const strip = (s) => decode(s).replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
const inner = (b, tag) => { const m = new RegExp(`<${tag}(?:\\s[^>]*)?>([\\s\\S]*?)</${tag}>`, 'i').exec(b); return m ? m[1] : ''; };
const attrsOf = (b, tag) => {
  const out = []; const re = new RegExp(`<${tag}\\b([^>]*?)/?>`, 'gi'); let m;
  while ((m = re.exec(b))) { const a = {}; m[1].replace(/([\w:-]+)\s*=\s*"([^"]*)"/g, (_x, k, v) => { a[k.toLowerCase()] = decode(v); return ''; }); out.push(a); }
  return out;
};
const httpUrl = (u) => (u && /^https?:\/\//i.test(u) ? u : '');

function pickImage(block) {
  const cands = [];
  for (const a of attrsOf(block, 'media:thumbnail')) if (httpUrl(a.url)) cands.push([+a.width || 0, a.url]);
  for (const a of attrsOf(block, 'media:content')) if (httpUrl(a.url) && (/image/.test(a.medium || '') || /^image\//.test(a.type || '') || (!a.medium && !a.type && /\.(jpe?g|png|webp)(\?|$)/i.test(a.url)))) cands.push([+a.width || 1, a.url]);
  for (const a of attrsOf(block, 'enclosure')) if (httpUrl(a.url) && /^image\//.test(a.type || '')) cands.push([1, a.url]);
  for (const a of attrsOf(block, 'ht:news_item_picture')) if (httpUrl(a.url)) cands.push([1, a.url]);
  if (cands.length) { cands.sort((x, y) => y[0] - x[0]); return upgrade(cands[0][1]); }
  const html = decode(inner(block, 'content:encoded') || inner(block, 'description') || inner(block, 'content') || inner(block, 'summary'));
  const m = /<img[^>]+src=["']([^"']+)["']/i.exec(html);
  return m ? upgrade(httpUrl(m[1])) : '';
}
function upgrade(u) { return u ? u.replace(/(ichef\.bbci\.co\.uk\/[^/]+\/)(?:ace\/)?(?:standard\/)?\d+\//, '$1976/').replace(/([?&])width=\d+/, '$1width=900') : u; }

function parseFeed(xml, source) {
  const items = [];
  const blocks = xml.match(/<(item|entry)\b[\s\S]*?<\/\1>/gi) || [];
  for (const b of blocks.slice(0, 30)) {
    const title = strip(inner(b, 'title'));
    let link = strip(inner(b, 'link'));
    if (!link) { const alt = attrsOf(b, 'link').find((a) => !a.rel || a.rel === 'alternate'); link = alt ? alt.href : ''; }
    if (!link) link = strip(inner(b, 'guid'));
    link = httpUrl(link);
    if (!title || !link) continue;
    const yt = strip(inner(b, 'yt:videoId'));
    let video = null;
    if (/^[\w-]{11}$/.test(yt)) video = { kind: 'youtube', id: yt };
    else { const v = attrsOf(b, 'media:content').find((a) => /^video\//.test(a.type || '') || a.medium === 'video'); if (v && httpUrl(v.url)) video = { kind: 'mp4', url: v.url }; }
    let image = pickImage(b);
    if (video && video.kind === 'youtube') image = `https://i.ytimg.com/vi/${video.id}/hqdefault.jpg`;
    const ts = Date.parse(strip(inner(b, 'pubDate') || inner(b, 'published') || inner(b, 'updated') || inner(b, 'dc:date'))) || 0;
    const summary = strip(inner(b, 'description') || inner(b, 'summary') || inner(b, 'media:description') || inner(b, 'content')).slice(0, 220);
    items.push({ id: crypto.createHash('sha1').update(link).digest('hex').slice(0, 12), title: title.slice(0, 200), summary, url: link, source, ts, image, video });
  }
  return items;
}

// ---------- fetching with cache (stale-while-error) ----------
const cache = new Map(); // key -> { at, data }
const TTL = 8 * 60 * 1000;
async function cached(key, fn, ttl = TTL) {
  const hit = cache.get(key);
  if (hit && Date.now() - hit.at < ttl) return hit.data;
  try { const data = await fn(); cache.set(key, { at: Date.now(), data }); return data; }
  catch (e) { if (hit) return hit.data; throw e; }
}

async function loadFeed([source, url]) {
  return cached(`feed:${url}`, async () => {
    const r = await fetchBuffer(url, { accept: 'application/rss+xml, application/atom+xml, application/xml, text/xml, */*' }, { maxBytes: 2 << 20, timeoutMs: 8000 });
    if (r.status !== 200) throw new Error(`feed ${r.status}`);
    return parseFeed(r.body.toString('utf8'), source);
  });
}

/** Articles whose feed has no picture: read og:image from the page head (first ~100KB), cached for hours. */
async function ogImage(url) {
  return cached(`og:${url}`, async () => {
    const r = await fetchUrl(url, { accept: 'text/html' }, { maxBytes: 8 << 20, timeoutMs: 5000 });
    let buf = '';
    try { for await (const c of r.stream) { buf += c.toString('latin1'); if (buf.length > 120000 || /<\/head>/i.test(buf)) break; } } finally { r.stream.destroy(); }
    const m = /<meta[^>]+(?:property|name)=["'](?:og:image|twitter:image)["'][^>]*content=["']([^"']+)["']/i.exec(buf)
           || /<meta[^>]+content=["']([^"']+)["'][^>]+(?:property|name)=["'](?:og:image|twitter:image)["']/i.exec(buf);
    return m ? httpUrl(decode(m[1])) : '';
  }, 6 * 3600 * 1000).catch(() => '');
}
// fire-and-forget: fills `image` on the cached objects so the next request already has pictures
async function enrichImages(items) {
  const todo = items.filter((i) => !i.image).slice(0, 18);
  for (let k = 0; k < todo.length; k += 6) await Promise.all(todo.slice(k, k + 6).map(async (i) => { i.image = await ogImage(i.url); }));
}

async function category(cat) {
  if (!FEEDS[cat]) throw Object.assign(new Error('unknown category'), { status: 400 });
  return cached(`cat:${cat}`, async () => {
    const lists = await Promise.all(FEEDS[cat].map((f) => loadFeed(f).then((x) => x.slice(0, cat === 'video' ? 8 : 12)).catch(() => [])));
    const seen = new Set(); const out = [];
    for (const it of lists.flat().sort((a, b) => b.ts - a.ts)) {
      const k = it.title.toLowerCase().replace(/\W+/g, '').slice(0, 60);
      if (seen.has(k)) continue; seen.add(k); out.push({ ...it, cat });
    }
    if (!out.length) throw new Error('no items');
    const final = out.slice(0, 48);
    enrichImages(final).catch(() => {});
    return final;
  });
}

/** "Explore": the best of every section, newest first, with a video up front. */
async function explore() {
  return cached('cat:explore', async () => {
    const parts = await Promise.all(['video', 'world', 'tech', 'entertainment', 'sports', 'science', 'finance'].map((c) => category(c).catch(() => [])));
    const pick = []; const seen = new Set();
    const take = (arr, n, needImage) => { let k = 0; for (const it of arr) { if (k >= n) break; if (seen.has(it.id) || (needImage && !it.image)) continue; seen.add(it.id); pick.push(it); k++; } };
    take(parts[0], 3, true);
    for (let i = 1; i < parts.length; i++) take(parts[i], 3, true);
    const head = pick.slice(0, 1), rest = pick.slice(1).sort((a, b) => b.ts - a.ts);
    return [...head, ...rest].slice(0, 40);
  });
}

async function news(cat) { return cat === 'explore' ? explore() : category(cat); }

// ---------- live scores (ESPN public scoreboards) ----------
const LEAGUES = [['basketball', 'nba', 'NBA'], ['football', 'nfl', 'NFL'], ['hockey', 'nhl', 'NHL'], ['soccer', 'eng.1', '英超'], ['soccer', 'uefa.champions', '欧冠']];
async function scores() {
  return cached('scores', async () => {
    const all = await Promise.all(LEAGUES.map(async ([sport, lg, label]) => {
      try {
        const r = await fetchBuffer(`https://site.api.espn.com/apis/site/v2/sports/${sport}/${lg}/scoreboard`, {}, { maxBytes: 2 << 20, timeoutMs: 7000 });
        const j = JSON.parse(r.body.toString('utf8'));
        return (j.events || []).slice(0, 8).map((e) => {
          const c = (e.competitions && e.competitions[0]) || {};
          const t = (c.competitors || []).map((x) => ({ name: (x.team && (x.team.abbreviation || x.team.shortDisplayName)) || '', logo: (x.team && x.team.logo) || '', score: x.score || '0', winner: !!x.winner }));
          const st = (e.status && e.status.type) || {};
          return { id: `${lg}-${e.id}`, league: label, state: st.state || 'pre', detail: st.shortDetail || '', teams: t, url: ((e.links || []).find((l) => (l.rel || []).includes('summary')) || {}).href || '' };
        });
      } catch { return []; }
    }));
    const rank = { in: 0, post: 1, pre: 2 };
    return all.flat().sort((a, b) => (rank[a.state] ?? 3) - (rank[b.state] ?? 3)).slice(0, 24);
  }, 60 * 1000);
}

// ---------- trends (Google Trends daily RSS) ----------
const GEOS = new Set(['US', 'GB', 'HK', 'TW', 'JP', 'KR', 'FR', 'DE', 'SG', 'AU', 'CA', 'IN']);
async function trends(geo = 'US') {
  geo = GEOS.has(geo) ? geo : 'US';
  return cached(`trends:${geo}`, async () => {
    const r = await fetchBuffer(`https://trends.google.com/trending/rss?geo=${geo}`, {}, { maxBytes: 1 << 20, timeoutMs: 8000 });
    const blocks = r.body.toString('utf8').match(/<item>[\s\S]*?<\/item>/gi) || [];
    return blocks.slice(0, 20).map((b, i) => {
      const nt = (b.match(/<ht:news_item>[\s\S]*?<\/ht:news_item>/i) || [''])[0];
      return { rank: i + 1, title: strip(inner(b, 'title')), traffic: strip(inner(b, 'ht:approx_traffic')), image: httpUrl(strip(inner(b, 'ht:picture'))),
               headline: strip(inner(nt, 'ht:news_item_title')), url: httpUrl(strip(inner(nt, 'ht:news_item_url'))) };
    }).filter((x) => x.title);
  }, 15 * 60 * 1000);
}

module.exports = { news, scores, trends, parseFeed, CATS };

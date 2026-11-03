#!/usr/bin/env bash
# og-inject.sh — inject Open Graph / Twitter Card preview tags into static HTML
# so shared links unfurl with a proper card (title + description + large image)
# instead of a bare URL. Idempotent: never injects into a page that already
# declares its own og:title. The one edit it makes to such a page is to move an
# hq-deploy card.png image URL (written by older versions) to card.jpg in place.
#
# Args:
#   $1 — output directory (build artifact root, served at the deploy domain)
#   $2 — base URL for absolute og:url / og:image: the app URL the hq-deploy API
#        returned (e.g. https://myapp.hq.work); optional
#   $3 — app name, used as the og:site_name and title fallback; optional
#   $4 — hq-deploy API base that serves the app's card (e.g. https://api.hq.work);
#        optional
#
# Output (one JSON line on stdout):
#   {"injected":N,"rewritten":N,"videoAdded":N,
#    "image":"card|generated|existing|none","video":"api|existing|none",
#    "changed":bool}
#
# Notes:
#   - Only ever rewrites .html files; binary/asset files are left alone.
#   - When no usable preview image exists and a base URL is given, points
#     og:image at hq-deploy's generated card for the app:
#     <api-base>/api/public/apps/<slug>/card.jpg, where <slug> is the first
#     label of the base URL host. <api-base> is $4 when given, else
#     https://api.<rest of the base URL host> (myapp.hq.work -> api.hq.work,
#     myapp.indigo-hq.com -> api.indigo-hq.com). Only when the base URL is empty
#     does it fall back to a plain 1200x630 placeholder PNG (_hq-og.png), built
#     with Node built-ins (zlib) -- no external deps, no network.
#   - og:video names a short muted clip that iMessage plays in place of the
#     image (other apps ignore it and keep og:image). A build file named
#     og*/opengraph*/social*/preview*/share*.mp4 wins; otherwise, with a base
#     URL, it is hq-deploy's <api-base>/api/public/apps/<slug>/preview.mp4.
#     That URL serves a recording of the page once one exists for a public
#     app, and answers 404 otherwise, so iMessage shows og:image instead.
#     Gated apps never get a video: preview bots are sent to the access page,
#     which never sees these tags.
#   - Pages that already carry their own og:title keep all their tags; only
#     the og:video block is added when they have no og:video of their own
#     (counted as videoAdded).
#   - twitter:card is summary_large_image whenever an image is present.
#   - Runs in well under a second; safe to call on every static deploy.

set -u

OUT_DIR="${1:-}"
BASE_URL="${2:-}"
APP_NAME="${3:-}"
CARD_API="${4:-}"

emit_noop() { printf '{"injected":0,"rewritten":0,"image":"none","video":"none","changed":false}\n'; exit 0; }

if [ -z "$OUT_DIR" ] || [ ! -d "$OUT_DIR" ]; then emit_noop; fi
if ! command -v node >/dev/null 2>&1; then emit_noop; fi

OG_OUT_DIR="$OUT_DIR" OG_BASE_URL="$BASE_URL" OG_APP_NAME="$APP_NAME" OG_CARD_API="$CARD_API" node - <<'NODE'
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const outDir = process.env.OG_OUT_DIR;
const baseUrl = (process.env.OG_BASE_URL || '').replace(/\/+$/, '');
const appName = process.env.OG_APP_NAME || 'App';
const cardApi = (process.env.OG_CARD_API || '').replace(/\/+$/, '');

const done = (obj) => { process.stdout.write(JSON.stringify(obj) + '\n'); process.exit(0); };

const htmlEscape = (s) => String(s)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
  .replace(/"/g, '&quot;').replace(/'/g, '&#39;');

function walk(dir, acc) {
  let ents;
  try { ents = fs.readdirSync(dir, { withFileTypes: true }); } catch { return acc; }
  for (const ent of ents) {
    const fp = path.join(dir, ent.name);
    if (ent.isDirectory()) {
      if (ent.name === 'node_modules' || ent.name.startsWith('.')) continue;
      walk(fp, acc);
    } else acc.push(fp);
  }
  return acc;
}

const allFiles = walk(outDir, []);
const htmlFiles = allFiles.filter(f => /\.html?$/i.test(f));
const hasOgTitle = (h) => /property\s*=\s*["']og:title["']/i.test(h);
const hasOgVideo = (h) => /property\s*=\s*["']og:video(?::url|:secure_url)?["']/i.test(h);

// Older versions pointed og:image / twitter:image at the card as card.png.
// hq-deploy now serves the card as card.jpg (card.png is a legacy alias), so
// rewrite those tags in place rather than adding a second set.
const IMAGE_META_RE = /<meta[^>]+(?:property|name)\s*=\s*["'](?:og:image|twitter:image)["'][^>]*>/gi;
const LEGACY_CARD_RE = /(\/api\/public\/apps\/[^/"'\s]+\/card)\.png(?=["'?#\s])/gi;
const rewriteLegacyCard = (h) => h.replace(IMAGE_META_RE, (tag) => tag.replace(LEGACY_CARD_RE, '$1.jpg'));

const targets = [];
// Author-tagged pages with no og:video of their own: only the video block is added.
const videoOnly = [];
let rewritten = 0;
for (const file of htmlFiles) {
  let html;
  try { html = fs.readFileSync(file, 'utf8'); } catch { continue; }
  if (hasOgTitle(html)) {
    const fixed = rewriteLegacyCard(html);
    if (fixed !== html) {
      try { fs.writeFileSync(file, fixed); rewritten++; }
      catch (e) { process.stderr.write(`og-inject: rewrite failed for ${file}: ${e.message}\n`); }
    }
    if (!hasOgVideo(fixed)) videoOnly.push({ file, html: fixed });
    continue;
  }
  targets.push({ file, html });
}
// Without a base URL there is no absolute video URL, so author-tagged pages
// have nothing to gain.
if (targets.length === 0 && (videoOnly.length === 0 || !baseUrl)) {
  done({ injected: 0, rewritten, videoAdded: 0, image: 'none', video: 'none', changed: rewritten > 0 });
}

const IMG_NAME = '_hq-og.png';
// hq-deploy renders a wallpaper share card per app at
// <api-base>/api/public/apps/<slug>/card.jpg (JPEG). The API base is the one
// the caller deployed through; without it, use api.<rest of the app host>.
// The same API serves the app's link-preview clip at .../preview.mp4: a
// recording of the page once a public app has one, else 404.
let cardUrl = null;
let apiVideoUrl = null;
try {
  if (baseUrl) {
    const labels = new URL(baseUrl).hostname.split('.');
    if (labels.length >= 3 && labels[0]) {
      let apiBase = `https://api.${labels.slice(1).join('.')}`;
      try {
        const u = cardApi ? new URL(cardApi) : null;
        if (u && u.protocol === 'https:') apiBase = u.origin;
      } catch { /* malformed $4: keep the derived base */ }
      cardUrl = `${apiBase}/api/public/apps/${labels[0]}/card.jpg`;
      apiVideoUrl = `${apiBase}/api/public/apps/${labels[0]}/preview.mp4`;
    }
  }
} catch { cardUrl = null; apiVideoUrl = null; }
let imageRel = null;
let imageStatus = 'none';

const imgCandidate = allFiles.find(f =>
  /(?:^|[/\\])(og|opengraph|social|preview|share)[^/\\]*\.(png|jpe?g)$/i.test(f));

if (imgCandidate) {
  imageRel = path.relative(outDir, imgCandidate).split(path.sep).join('/');
  imageStatus = 'existing';
} else if (cardUrl) {
  imageStatus = 'card';
} else {
  const W = 1200, H = 630;
  const top = [10, 14, 26], bot = [24, 32, 58];
  const raw = Buffer.alloc(H * (1 + W * 3));
  for (let y = 0; y < H; y++) {
    const t = H === 1 ? 0 : y / (H - 1);
    const r = Math.round(top[0] + (bot[0] - top[0]) * t);
    const g = Math.round(top[1] + (bot[1] - top[1]) * t);
    const b = Math.round(top[2] + (bot[2] - top[2]) * t);
    const rs = y * (1 + W * 3);
    raw[rs] = 0;
    for (let x = 0; x < W; x++) {
      const o = rs + 1 + x * 3;
      raw[o] = r; raw[o + 1] = g; raw[o + 2] = b;
    }
  }
  const crcTable = (() => {
    const tbl = new Int32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
      tbl[n] = c;
    }
    return tbl;
  })();
  const crc32 = (buf) => {
    let c = 0xFFFFFFFF;
    for (let i = 0; i < buf.length; i++) c = crcTable[(c ^ buf[i]) & 0xFF] ^ (c >>> 8);
    return (c ^ 0xFFFFFFFF) >>> 0;
  };
  const chunk = (type, data) => {
    const len = Buffer.alloc(4); len.writeUInt32BE(data.length, 0);
    const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
    const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(body), 0);
    return Buffer.concat([len, body, crc]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(W, 0); ihdr.writeUInt32BE(H, 4);
  ihdr[8] = 8; ihdr[9] = 2;
  const png = Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
  try {
    fs.writeFileSync(path.join(outDir, IMG_NAME), png);
    imageRel = IMG_NAME;
    imageStatus = 'generated';
  } catch { imageStatus = 'none'; }
}

const absUrl = (rel) => {
  if (!rel) return null;
  const clean = rel.replace(/^\/+/, '');
  return baseUrl ? `${baseUrl}/${clean}` : `/${clean}`;
};
const imgAbs = imageStatus === 'card' ? cardUrl : absUrl(imageRel);

const videoCandidate = allFiles.find(f =>
  /(?:^|[/\\])(og|opengraph|social|preview|share)[^/\\]*\.mp4$/i.test(f));
let videoAbs = null;
let videoStatus = 'none';
if (videoCandidate && baseUrl) {
  videoAbs = absUrl(path.relative(outDir, videoCandidate).split(path.sep).join('/'));
  videoStatus = 'existing';
} else if (apiVideoUrl) {
  videoAbs = apiVideoUrl;
  videoStatus = 'api';
}

const videoTags = videoAbs ? [
  `<meta property="og:video" content="${htmlEscape(videoAbs)}">`,
  `<meta property="og:video:secure_url" content="${htmlEscape(videoAbs)}">`,
  `<meta property="og:video:type" content="video/mp4">`,
  `<meta property="og:video:width" content="1200">`,
  `<meta property="og:video:height" content="630">`,
] : [];

const insertBlock = (html, block) => {
  if (/<head[^>]*>/i.test(html)) return html.replace(/(<head[^>]*>)/i, `$1${block}`);
  if (/<html[^>]*>/i.test(html)) return html.replace(/(<html[^>]*>)/i, `$1\n<head>${block}</head>`);
  return `<head>${block}</head>\n` + html;
};

let injected = 0;
for (const { file, html } of targets) {
  let title = appName;
  const tm = html.match(/<title[^>]*>([\s\S]*?)<\/title>/i);
  if (tm && tm[1].trim()) title = tm[1].trim().replace(/\s+/g, ' ');

  let desc = '';
  const dm = html.match(/<meta[^>]+name\s*=\s*["']description["'][^>]*>/i);
  if (dm) {
    const cm = dm[0].match(/content\s*=\s*["']([\s\S]*?)["']/i);
    if (cm) desc = cm[1].trim();
  }
  if (!desc) {
    const pm = html.match(/<p[^>]*>([\s\S]*?)<\/p>/i);
    if (pm) desc = pm[1].replace(/<[^>]+>/g, '').trim().replace(/\s+/g, ' ');
  }
  if (desc.length > 200) desc = desc.slice(0, 197).replace(/\s+\S*$/, '') + '…';

  let rel = path.relative(outDir, file).split(path.sep).join('/');
  rel = rel.replace(/index\.html?$/i, '');
  const pageUrl = baseUrl ? (rel ? `${baseUrl}/${rel}` : `${baseUrl}/`) : null;

  const tags = [];
  tags.push(`<meta property="og:type" content="website">`);
  tags.push(`<meta property="og:title" content="${htmlEscape(title)}">`);
  if (desc) tags.push(`<meta property="og:description" content="${htmlEscape(desc)}">`);
  if (appName) tags.push(`<meta property="og:site_name" content="${htmlEscape(appName)}">`);
  if (pageUrl) tags.push(`<meta property="og:url" content="${htmlEscape(pageUrl)}">`);
  if (imgAbs) {
    tags.push(`<meta property="og:image" content="${htmlEscape(imgAbs)}">`);
    tags.push(`<meta property="og:image:width" content="1200">`);
    tags.push(`<meta property="og:image:height" content="630">`);
  }
  if (videoAbs) tags.push(...videoTags);
  tags.push(`<meta name="twitter:card" content="${imgAbs ? 'summary_large_image' : 'summary'}">`);
  tags.push(`<meta name="twitter:title" content="${htmlEscape(title)}">`);
  if (desc) tags.push(`<meta name="twitter:description" content="${htmlEscape(desc)}">`);
  if (imgAbs) tags.push(`<meta name="twitter:image" content="${htmlEscape(imgAbs)}">`);

  const block = '\n  <!-- hq-deploy: social preview tags -->\n  ' + tags.join('\n  ') + '\n';

  try { fs.writeFileSync(file, insertBlock(html, block)); injected++; } catch {}
}

let videoAdded = 0;
if (videoAbs) {
  for (const { file, html } of videoOnly) {
    const block = '\n  <!-- hq-deploy: link-preview video -->\n  ' + videoTags.join('\n  ') + '\n';
    try { fs.writeFileSync(file, insertBlock(html, block)); videoAdded++; } catch {}
  }
}

done({
  injected,
  rewritten,
  videoAdded,
  image: injected > 0 ? imageStatus : 'none',
  video: injected > 0 || videoAdded > 0 ? videoStatus : 'none',
  changed: injected > 0 || rewritten > 0 || videoAdded > 0 || imageStatus === 'generated',
});
NODE

#!/usr/bin/env bash
# og-inject.sh — inject Open Graph / Twitter Card preview tags into static HTML
# so shared links unfurl with a proper card (title + description + large image)
# instead of a bare URL. Idempotent: never touches a page that already declares
# its own og:title.
#
# Args:
#   $1 — output directory (build artifact root, served at the deploy domain)
#   $2 — base URL for absolute og:url / og:image (e.g. https://app.indigo-hq.com); optional
#   $3 — app name, used as the og:site_name and title fallback; optional
#
# Output (one JSON line on stdout):
#   {"injected":N,"image":"generated|existing|none","changed":bool}
#
# Notes:
#   - Only ever rewrites .html files; binary/asset files are left alone.
#   - When no usable preview image exists, generates a branded 1200x630 PNG
#     (_hq-og.png) using only Node built-ins (zlib) -- no external deps, no network.
#   - twitter:card is summary_large_image whenever an image is present.
#   - Runs in well under a second; safe to call on every static deploy.

set -u

OUT_DIR="${1:-}"
BASE_URL="${2:-}"
APP_NAME="${3:-}"

emit_noop() { printf '{"injected":0,"image":"none","changed":false}\n'; exit 0; }

if [ -z "$OUT_DIR" ] || [ ! -d "$OUT_DIR" ]; then emit_noop; fi
if ! command -v node >/dev/null 2>&1; then emit_noop; fi

OG_OUT_DIR="$OUT_DIR" OG_BASE_URL="$BASE_URL" OG_APP_NAME="$APP_NAME" node - <<'NODE'
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const outDir = process.env.OG_OUT_DIR;
const baseUrl = (process.env.OG_BASE_URL || '').replace(/\/+$/, '');
const appName = process.env.OG_APP_NAME || 'App';

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

const targets = [];
for (const file of htmlFiles) {
  let html;
  try { html = fs.readFileSync(file, 'utf8'); } catch { continue; }
  if (hasOgTitle(html)) continue;
  targets.push({ file, html });
}
if (targets.length === 0) done({ injected: 0, image: 'none', changed: false });

const IMG_NAME = '_hq-og.png';
let imageRel = null;
let imageStatus = 'none';

const imgCandidate = allFiles.find(f =>
  /(?:^|[/\\])(og|opengraph|social|preview|share)[^/\\]*\.(png|jpe?g)$/i.test(f));

if (imgCandidate) {
  imageRel = path.relative(outDir, imgCandidate).split(path.sep).join('/');
  imageStatus = 'existing';
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
const imgAbs = absUrl(imageRel);

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
  tags.push(`<meta name="twitter:card" content="${imgAbs ? 'summary_large_image' : 'summary'}">`);
  tags.push(`<meta name="twitter:title" content="${htmlEscape(title)}">`);
  if (desc) tags.push(`<meta name="twitter:description" content="${htmlEscape(desc)}">`);
  if (imgAbs) tags.push(`<meta name="twitter:image" content="${htmlEscape(imgAbs)}">`);

  const block = '\n  <!-- hq-deploy: social preview tags -->\n  ' + tags.join('\n  ') + '\n';

  let out;
  if (/<head[^>]*>/i.test(html)) {
    out = html.replace(/(<head[^>]*>)/i, `$1${block}`);
  } else if (/<html[^>]*>/i.test(html)) {
    out = html.replace(/(<html[^>]*>)/i, `$1\n<head>${block}</head>`);
  } else {
    out = `<head>${block}</head>\n` + html;
  }

  try { fs.writeFileSync(file, out); injected++; } catch {}
}

done({ injected, image: imageStatus, changed: injected > 0 || imageStatus === 'generated' });
NODE

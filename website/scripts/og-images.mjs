// OG 分享图生成(任务书 §4.2:每页一张 1200×630,构建时按模板生成)。
// 在 astro build 之后运行:扫描 dist 内每页的 <title>/og:title/canonical,
// 用同一模板渲染 SVG → sharp 栅格化 → dist/og/<slug>.png。
// 另有 --icons 模式:生成 public/apple-touch-icon.png(180×180,提交进仓库)。
import { readdir, readFile, writeFile, mkdir } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import sharp from 'sharp';
import { fileURLToPath } from 'node:url';
import { siteConfig } from '../src/config.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const website = path.resolve(here, '..');
const dist = path.join(website, 'dist');

const INK = '#1b2430';
const PAPER = '#fbfaf7';
const ACCENT = '#177e4b';

function esc(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

// 按近似字宽(0.55em)折行;超过 maxLines 行则缩小字号重试。
function wrap(text, fontSize, maxWidth) {
  const charW = fontSize * 0.55;
  const perLine = Math.floor(maxWidth / charW);
  const words = text.split(/\s+/);
  const lines = [];
  let cur = '';
  for (const w of words) {
    if ((cur + ' ' + w).trim().length > perLine && cur) {
      lines.push(cur);
      cur = w;
    } else {
      cur = (cur + ' ' + w).trim();
    }
  }
  if (cur) lines.push(cur);
  return lines;
}

function layoutHeadline(text) {
  for (const size of [64, 54, 46]) {
    const lines = wrap(text, size, 1000);
    if (lines.length <= 3) return { size, lines };
  }
  return { size: 46, lines: wrap(text, 46, 1000).slice(0, 3) };
}

function ogSvg({ headline, domain }) {
  const { size, lines } = layoutHeadline(headline);
  const lineHeight = size * 1.22;
  const blockH = lines.length * lineHeight;
  const firstY = 315 - blockH / 2 + size * 0.85;
  const text = lines
    .map((l, i) => `<text x="80" y="${(firstY + i * lineHeight).toFixed(0)}" font-size="${size}" font-weight="800" fill="${INK}">${esc(l)}</text>`)
    .join('\n    ');
  return `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="630" viewBox="0 0 1200 630">
  <rect width="1200" height="630" fill="${PAPER}"/>
  <rect x="0" y="0" width="1200" height="10" fill="${ACCENT}"/>
  <rect x="80" y="72" width="46" height="46" rx="11" fill="${ACCENT}"/>
  <path d="M91 97l8 8 17-18" fill="none" stroke="#fff" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/>
  <text x="142" y="106" font-size="30" font-weight="700" fill="${INK}">${esc(siteConfig.appName)}</text>
  ${text}
  <text x="80" y="560" font-size="26" font-weight="500" fill="#7b8794">${esc(domain)}</text>
</svg>`;
}

async function* walkHtml(dir) {
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) yield* walkHtml(full);
    else if (entry.name.endsWith('.html') && entry.name !== '404.html') yield full;
  }
}

async function generateOg() {
  const outDir = path.join(dist, 'og');
  await mkdir(outDir, { recursive: true });

  let count = 0;
  for await (const file of walkHtml(dist)) {
    const html = await readFile(file, 'utf-8');
    const ogTitle = html.match(/<meta property="og:title" content="([^"]*)"/)?.[1];
    if (!ogTitle) throw new Error(`No og:title in ${file}`);
    const svg = ogSvg({ headline: ogTitle, domain: siteConfig.domain });
    const rel = path.relative(dist, file).replace(/\.html$/, '');
    const slug = rel === 'index' ? 'home' : rel.split(path.sep).join('-');
    await sharp(Buffer.from(svg)).png().toFile(path.join(outDir, `${slug}.png`));
    console.log(`og/${slug}.png  ←  ${ogTitle}`);
    count += 1;
  }
  console.log(`${count} OG images generated.`);
}

async function generateIcons() {
  const svg = `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="180" height="180" viewBox="0 0 180 180">
  <rect width="180" height="180" rx="40" fill="${ACCENT}"/>
  <path d="M50 94l20 20 45-47" fill="none" stroke="#fff" stroke-width="14" stroke-linecap="round" stroke-linejoin="round"/>
</svg>`;
  await sharp(Buffer.from(svg)).png().toFile(path.join(website, 'public', 'apple-touch-icon.png'));
  console.log('public/apple-touch-icon.png generated.');
}

if (process.argv.includes('--icons')) {
  if (!existsSync(path.join(website, 'public'))) {
    throw new Error('public/ missing — run from website root');
  }
  await generateIcons();
} else {
  if (!existsSync(dist)) throw new Error('dist/ missing — run `astro build` first');
  await generateOg();
}

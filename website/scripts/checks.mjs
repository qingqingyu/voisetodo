// 构建时验收检查(任务书 §9)。dist 生成后运行,任何一条不过 → 退出码 1,构建失败。
// 检查:title/description 唯一且不超长;canonical 规范;og 图存在;单 H1;
// 商店链接全带 pt+ct;图片 alt/尺寸/懒加载;禁用说法扫描(§0.2,带许可清单);
// sitemap/robots 完整性;JSON-LD 可解析且按页型齐全;零客户端 JS;单语言不输出 hreflang。
import { readdir, readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { siteConfig, siteUrl, appStoreBase } from '../src/config.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const dist = path.resolve(here, '..', 'dist');

const failures = [];
const notes = [];
function fail(msg) {
  failures.push(msg);
}
function note(msg) {
  notes.push(msg);
}

async function* walk(dir) {
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) yield* walk(full);
    else yield full;
  }
}

// ---------- 收集页面 ----------
const htmlFiles = [];
for await (const f of walk(dist)) {
  if (f.endsWith('.html')) htmlFiles.push(f);
}
htmlFiles.sort();

const pages = [];
for (const file of htmlFiles) {
  const html = await readFile(file, 'utf-8');
  const rel = path.relative(dist, file).replace(/\.html$/, '');
  const url = rel === 'index' ? '/' : '/' + rel.split(path.sep).join('/');
  pages.push({
    file,
    url,
    html,
    is404: rel === '404',
    // 草稿判定只针对指南详情页(列表页也渲染 draft-badge 徽章,但本身不是草稿)
    isGuideDraft: url.startsWith('/guides/') && url !== '/guides' && html.includes('draft-badge'),
    title: html.match(/<title>([^<]*)<\/title>/)?.[1] ?? '',
    description: html.match(/<meta name="description" content="([^"]*)"/)?.[1] ?? '',
    ogTitle: html.match(/<meta property="og:title" content="([^"]*)"/)?.[1] ?? '',
    canonical: html.match(/<link rel="canonical" href="([^"]*)"/)?.[1] ?? '',
    ogImage: html.match(/<meta property="og:image" content="([^"]*)"/)?.[1] ?? '',
  });
}
if (pages.length === 0) fail('No HTML pages found in dist/');

// ---------- 1. title / description(§9:唯一 + 不超长)----------
const seenTitles = new Map();
const seenDescs = new Map();
const seenOgTitles = new Map();
for (const p of pages) {
  if (p.title.length > 60) fail(`[${p.url}] title ${p.title.length} chars > 60: "${p.title}"`);
  if (seenTitles.has(p.title)) fail(`[${p.url}] duplicate title with ${seenTitles.get(p.title)}: "${p.title}"`);
  seenTitles.set(p.title, p.url);

  if (!p.description) fail(`[${p.url}] missing meta description`);
  else {
    if (p.description.length > 155) fail(`[${p.url}] description ${p.description.length} chars > 155`);
    if (seenDescs.has(p.description)) fail(`[${p.url}] duplicate description with ${seenDescs.get(p.description)}`);
    seenDescs.set(p.description, p.url);
  }

  if (seenOgTitles.has(p.ogTitle)) fail(`[${p.url}] duplicate og:title with ${seenOgTitles.get(p.ogTitle)}: "${p.ogTitle}"`);
  seenOgTitles.set(p.ogTitle, p.url);
}

// ---------- 2. canonical / og 图 / noindex ----------
const seenCanonicals = new Map();
for (const p of pages) {
  if (!p.canonical) {
    fail(`[${p.url}] missing canonical`);
    continue;
  }
  if (!p.canonical.startsWith(siteUrl)) fail(`[${p.url}] canonical not absolute under site URL: ${p.canonical}`);
  if (p.url !== '/' && p.canonical.endsWith('/')) fail(`[${p.url}] canonical has trailing slash`);
  if (p.canonical !== siteUrl + p.url) fail(`[${p.url}] canonical ${p.canonical} != ${siteUrl + p.url}`);
  if (seenCanonicals.has(p.canonical)) fail(`[${p.url}] duplicate canonical with ${seenCanonicals.get(p.canonical)}`);
  seenCanonicals.set(p.canonical, p.url);

  // og:image 文件必须真实存在(404 页无 og 图可接受)
  if (!p.is404) {
    if (!p.ogImage) fail(`[${p.url}] missing og:image`);
    else {
      const ogRel = p.ogImage.replace(siteUrl, '');
      if (!existsSync(path.join(dist, ogRel))) fail(`[${p.url}] og:image file missing: ${ogRel}`);
    }
  }

  const noindex = p.html.includes('name="robots" content="noindex"');
  const shouldBeNoindex = p.is404 || p.isGuideDraft;
  if (noindex !== shouldBeNoindex) {
    fail(`[${p.url}] noindex=${noindex}, expected ${shouldBeNoindex}`);
  }
}

// ---------- 3. 单 H1 ----------
for (const p of pages) {
  const h1s = p.html.match(/<h1[\s>]/g)?.length ?? 0;
  if (h1s !== 1) fail(`[${p.url}] ${h1s} <h1> elements (expected 1)`);
}

// ---------- 4. App Store 链接来源参数(§4.7)----------
const storeLinkRe = /href="(https:\/\/apps\.apple\.com\/[^"]*)"/g;
for (const p of pages) {
  for (const [, href] of p.html.matchAll(storeLinkRe)) {
    if (!href.startsWith(appStoreBase)) fail(`[${p.url}] store link not built from config: ${href}`);
    if (!/[?&]ct=[\w-]+/.test(href)) fail(`[${p.url}] store link missing ct param: ${href}`);
    if (!/[?&]pt=/.test(href)) fail(`[${p.url}] store link missing pt param: ${href}`);
  }
}

// ---------- 5. 图片 alt / 尺寸 / 懒加载(§4.5)----------
// 首屏图豁免懒加载:首页 hero 的 01-recording。
const EAGER_OK = new Set(['/']);
for (const p of pages) {
  for (const img of p.html.matchAll(/<img\b[^>]*>/g)) {
    const tag = img[0];
    const src = tag.match(/src="([^"]*)"/)?.[1] ?? '';
    if (!tag.includes('alt=') || tag.match(/alt=""/)) fail(`[${p.url}] img without alt: ${src}`);
    if (!/\bwidth="\d+"/.test(tag)) fail(`[${p.url}] img without width: ${src}`);
    if (!/\bheight="\d+"/.test(tag)) fail(`[${p.url}] img without height: ${src}`);
    const lazy = /loading="lazy"/.test(tag);
    if (!lazy && !EAGER_OK.has(p.url)) fail(`[${p.url}] above-fold exemption only allowed on homepage: ${src}`);
    if (EAGER_OK.has(p.url) && src.includes('01-recording') && lazy) {
      fail(`[${p.url}] hero image should be eager: ${src}`);
    }
    if (src.startsWith('/screens/') && !existsSync(path.join(dist, src))) {
      fail(`[${p.url}] screenshot missing from dist: ${src}`);
    }
  }
}

// ---------- 6. 禁用说法扫描(§0.2 右列)----------
// 逐行扫描正文(去标签);否定语境(官方要求的坦白说明)走 ALLOWED_PHRASES。
const ALLOWED_PHRASES = [
  'iPad, Mac, and Android are not supported',
  'iPad, Mac, Apple Watch, and Android are not supported',
  'No multi-device sync today',
  'Requires iPhone with iOS 26 or later',
];
const BANNED_PATTERNS = [
  [/\bunlimited\b/i, 'unlimited claims'],
  [/free forever|completely free|100% free/i, 'misleading free claims'],
  [/\boffline\b/i, 'offline claims (allowed only as honest offline-fallback wording without the word itself)'],
  [/\bsync(ed|ing|s)?\b/i, 'sync claims (allowed only in the required "no multi-device sync" disclosure)'],
  [/\bcur(e|es|ed|ing)\b|clinic(al|ally)?\b|therap(y|ist)\b/i, 'medical claims'],
  // treat* 只在贴近医学语境时才算宣称(普通动词用法放行;ADHD 文案另由下方规则单独拦)
  [/\btreat(s|ed|ing)?\b[^.\n]{0,60}\b(adhd|symptom|disorder|condition|health|attention)\b/i, 'medical claims'],
  [/\b(adhd|symptom|disorder|attention deficit)\b[^.\n]{0,60}\btreat(s|ed|ing)?\b/i, 'medical claims'],
  [/\bhealth benefit|scientifically proven|clinically proven\b/i, 'medical claims'],
  [/never leaves your (device|phone)/i, 'over-broad data claim'],
  [/data never leaves/i, 'over-broad data claim'],
  [/\bandroid\b|\bipad\b|\bapple watch\b|for mac\b|mac app\b/i, 'unsupported-platform mentions (negations only)'],
  [/adhd/i, 'ADHD copy reserved for phase 3 with real experience'],
];

function textOf(html) {
  return html
    .replace(/<script[\s\S]*?<\/script>/g, ' ')
    .replace(/<style[\s\S]*?<\/style>/g, ' ')
    .replace(/<[^>]+>/g, '\n')
    .replace(/&amp;/g, '&')
    .replace(/&rarr;/g, '→')
    .replace(/&middot;/g, '·');
}

for (const p of pages) {
  const text = textOf(p.html);
  // 先整体检查「许可短语所在行」,逐行处理
  const lines = text.split('\n').map((l) => l.trim()).filter(Boolean);
  for (const line of lines) {
    let work = line;
    for (const phrase of ALLOWED_PHRASES) {
      work = work.replace(new RegExp(phrase, 'gi'), '');
    }
    for (const [re, why] of BANNED_PATTERNS) {
      const m = work.match(re);
      if (m) {
        fail(`[${p.url}] banned wording (${why}): …${line.slice(0, 140)}`);
        break;
      }
    }
  }
}

// ---------- 7. sitemap / robots(§4.4)----------
const sitemapXml = await readFile(path.join(dist, 'sitemap.xml'), 'utf-8');
const sitemapUrls = [...sitemapXml.matchAll(/<loc>([^<]+)<\/loc>/g)].map((m) => m[1]);
const robotsTxt = await readFile(path.join(dist, 'robots.txt'), 'utf-8');

const expectedInSitemap = pages
  .filter((p) => !p.is404 && !p.isGuideDraft)
  .map((p) => siteUrl + (p.url === '/' ? '/' : p.url));
for (const u of expectedInSitemap) {
  if (!sitemapUrls.includes(u)) fail(`sitemap.xml missing: ${u}`);
}
for (const u of sitemapUrls) {
  if (!expectedInSitemap.includes(u)) fail(`sitemap.xml has unexpected url: ${u}`);
}
for (const u of sitemapUrls) {
  if (u !== siteUrl + '/' && u.endsWith('/')) fail(`sitemap url with trailing slash: ${u}`);
}
for (const bot of ['OAI-SearchBot', 'GPTBot', 'PerplexityBot', 'ClaudeBot', 'Google-Extended']) {
  if (!robotsTxt.includes(bot)) fail(`robots.txt missing AI bot: ${bot}`);
}
if (!robotsTxt.includes(`Sitemap: ${siteUrl}/sitemap.xml`)) fail('robots.txt missing sitemap pointer');

// llms.txt(§4.4 可选,README 宣称域名跟随 config):校验存在且由 config 生成
const llmsPath = path.join(dist, 'llms.txt');
if (!existsSync(llmsPath)) fail('llms.txt missing from dist (generated endpoint expected)');
else if (!(await readFile(llmsPath, 'utf-8')).includes(siteUrl)) fail('llms.txt not generated from config (missing site URL)');

// ---------- 8. JSON-LD(§4.3)----------
function jsonLdBlocks(html) {
  return [...html.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)].map((m) => {
    try {
      return JSON.parse(m[1]);
    } catch {
      return { '@type': 'INVALID' };
    }
  });
}
for (const p of pages) {
  const blocks = jsonLdBlocks(p.html);
  if (blocks.some((b) => b['@type'] === 'INVALID')) fail(`[${p.url}] JSON-LD parse error`);
  const types = blocks.map((b) => b['@type']);
  if (!types.includes('WebSite')) fail(`[${p.url}] missing WebSite schema`);
  if (!types.includes('Organization')) fail(`[${p.url}] missing Organization schema`);

  if (p.url === '/' || p.url === '/features') {
    const app = blocks.find((b) => b['@type'] === 'MobileApplication');
    if (!app) fail(`[${p.url}] missing MobileApplication schema`);
    else if (app.offers?.price !== '0') fail(`[${p.url}] MobileApplication offers.price must be "0"`);
  }

  if (p.url !== '/' && !p.is404) {
    if (!types.includes('BreadcrumbList')) fail(`[${p.url}] missing BreadcrumbList schema`);
  }

  if (p.url.startsWith('/guides/') && p.url !== '/guides') {
    const art = blocks.find((b) => b['@type'] === 'Article');
    if (!art) fail(`[${p.url}] missing Article schema`);
    else {
      for (const key of ['headline', 'datePublished', 'dateModified', 'author', 'image']) {
        if (!art[key]) fail(`[${p.url}] Article missing ${key}`);
      }
    }
  }

  // FAQ 页:结构化数据条数 == 可见 details 条数(§4.3 一致性)
  const faqSchema = blocks.find((b) => b['@type'] === 'FAQPage');
  const visible = p.html.match(/<details>/g)?.length ?? 0;
  if (faqSchema && visible !== faqSchema.mainEntity.length) {
    fail(`[${p.url}] FAQPage has ${faqSchema.mainEntity.length} items but ${visible} visible <details>`);
  }
  const faqPages = ['/', '/voice-to-do-list', '/lock-screen-to-do-list', '/iphone-to-do-widget', '/support'];
  if (faqPages.includes(p.url) && !faqSchema) fail(`[${p.url}] expected FAQPage schema`);
}

// ---------- 9. 零客户端 JS(§4.1)----------
for (const p of pages) {
  const scripts = [...p.html.matchAll(/<script\b([^>]*)>/g)].map((m) => m[1]);
  for (const attrs of scripts) {
    if (!attrs.includes('application/ld+json')) fail(`[${p.url}] client-side script found: <script${attrs.slice(0, 60)}>`);
  }
}

// ---------- 10. hreflang 单语言不输出(§4.1 多语言预留)----------
if (siteConfig.locales.length === 1) {
  for (const p of pages) {
    if (/<link rel="alternate"/.test(p.html)) fail(`[${p.url}] hreflang emitted with single locale`);
  }
  note('hreflang generator idle (single locale) — verified');
}

// ---------- 汇总 ----------
console.log(`Checked ${pages.length} pages.`);
for (const n of notes) console.log(`  note: ${n}`);
if (failures.length) {
  console.error(`\nFAILED (${failures.length}):`);
  for (const f of failures) console.error(`  ✗ ${f}`);
  process.exit(1);
} else {
  console.log('\nAll build checks passed.');
}

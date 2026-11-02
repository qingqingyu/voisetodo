// 截图优化:仓库根 screenshots/en/*.png → website/public/screens/*.webp,
// 并生成 src/data/screens.mjs(真实宽高,供 <img width/height> 用,零 CLS)。
// 源图变更后重跑:npm run images(幂等,按 mtime 跳过未变文件)。
import { mkdir, readFile, writeFile, stat } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import sharp from 'sharp';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const website = path.resolve(here, '..');
const repoRoot = path.resolve(website, '..');

// 页面实际引用的截图清单(Shot 组件 name)。新增引用先加到这里。
const SHOTS = [
  '01-recording',
  '02-confirmsheet',
  '03-month',
  '04-today',
  '05-review',
];

const MAX_WIDTH = 1100; // 大档:hero/宽栏,3x 屏留足
const SMALL_WIDTH = 640; // 小档:窄幅列(shot-narrow 等)
const QUALITY = 80;

const outDir = path.join(website, 'public', 'screens');
await mkdir(outDir, { recursive: true });

const results = [];
for (const name of SHOTS) {
  const src = path.join(repoRoot, 'screenshots', 'en', `${name}.png`);
  if (!existsSync(src)) throw new Error(`Missing screenshot source: ${src}`);

  const srcMtime = (await stat(src)).mtimeMs;
  let skipped = true;
  for (const width of [SMALL_WIDTH, MAX_WIDTH]) {
    const dst = path.join(outDir, `${name}-${width}.webp`);
    const dstMtime = existsSync(dst) ? (await stat(dst)).mtimeMs : 0;
    if (dstMtime >= srcMtime && !process.argv.includes('--force')) continue;
    await sharp(src)
      .rotate() // 尊重 EXIF 方向
      .resize({ width, withoutEnlargement: true })
      .webp({ quality: QUALITY })
      .toFile(dst);
    skipped = false;
  }

  const meta = await sharp(path.join(outDir, `${name}-${MAX_WIDTH}.webp`)).metadata();
  const metaSmall = await sharp(path.join(outDir, `${name}-${SMALL_WIDTH}.webp`)).metadata();
  results.push({ name, w: meta.width, h: meta.height, smallW: metaSmall.width, smallH: metaSmall.height, skipped });
}

// 生成 screens.mjs(提交进仓库,构建不依赖 sharp 跑这步)。
const lines = results.map(
  (r) => `  '${r.name}': { w: ${r.w}, h: ${r.h}, smallW: ${r.smallW}, smallH: ${r.smallH} },`
);
const file = `// 由 scripts/optimize-images.mjs 生成 —— 请勿手改;截图更新后重跑 npm run images。\nexport const screens = {\n${lines.join('\n')}\n};\n`;
await writeFile(path.join(website, 'src', 'data', 'screens.mjs'), file, 'utf-8');

for (const r of results) {
  console.log(`${r.skipped ? 'kept ' : 'wrote'} ${r.name} webp  ${r.w}x${r.h} + ${r.smallW}x${r.smallH}${r.skipped ? ' (unchanged)' : ''}`);
}

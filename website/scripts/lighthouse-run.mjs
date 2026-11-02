// Lighthouse 移动端验收(任务书 §4.5 / §9):每类页面各测一个 —— 落地页(/)、
// 事实页(/features)、文章页(一篇指南)。阈值:Performance ≥95、Accessibility ≥95、
// Best Practices ≥95、SEO 100。文章页当前是草稿(noindex),SEO 审计必然扣分,
// 因此该页只报告不设阈值(结果文档记录此偏离;审改发布后翻 draft:false 即达标)。
// 报告输出到 lighthouse-reports/(gitignore,不入库;分数汇总进结果文档)。
import { mkdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createStaticServer } from './serve.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const website = path.resolve(here, '..');
const dist = path.join(website, 'dist');
const outDir = path.join(website, 'lighthouse-reports');

const { default: lighthouse } = await import('lighthouse');
const chromeLauncherModule = await import('chrome-launcher');
const launchChrome = chromeLauncherModule.launch ?? chromeLauncherModule.default?.launch;

const PAGES = [
  { name: 'home-landing', url: '/', assert: true },
  { name: 'features-fact', url: '/features', assert: true },
  { name: 'guide-article', url: '/guides/plan-your-day-in-2-minutes', assert: false }, // 草稿 noindex,只报告
];

const THRESHOLDS = { performance: 95, accessibility: 95, 'best-practices': 95, seo: 100 };

const server = createStaticServer(dist);
await new Promise((r) => server.listen(4318, r));
console.log('Serving dist on :4318');

await mkdir(outDir, { recursive: true });

let failed = false;
try {
  const chrome = await launchChrome({ chromeFlags: ['--headless=new', '--no-sandbox'] });
  try {
    for (const page of PAGES) {
      const result = await lighthouse(`http://localhost:4318${page.url}`, {
        port: chrome.port,
        output: ['json', 'html'],
        onlyCategories: ['performance', 'accessibility', 'best-practices', 'seo'],
      });
      const { categories } = result.lhr;
      const scores = {};
      for (const key of Object.keys(THRESHOLDS)) {
        scores[key] = Math.round((categories[key]?.score ?? 0) * 100);
      }
      const line = Object.entries(scores).map(([k, v]) => `${k} ${v}`).join('  ');
      console.log(`${page.name.padEnd(16)} ${line}${page.assert ? '' : '  (report-only, draft noindex)'}`);

      for (const type of ['json', 'html']) {
        const report = Array.isArray(result.report) ? result.report[[`json`, `html`].indexOf(type)] : result.report;
        const name = type === 'html' ? `${page.name}.report.html` : `${page.name}.report.json`;
        const { writeFile } = await import('node:fs/promises');
        await writeFile(path.join(outDir, name), report);
      }

      if (page.assert) {
        for (const [key, min] of Object.entries(THRESHOLDS)) {
          if (scores[key] < min) {
            console.error(`  ✗ ${page.name}: ${key} ${scores[key]} < ${min}`);
            failed = true;
          }
        }
      }
    }
  } finally {
    await chrome.kill();
  }
} finally {
  server.close();
}

process.exit(failed ? 1 : 0);

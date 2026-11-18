// 工具页结果/错误页的服务端渲染壳(零客户端 JS:全站验收规则同样适用于
// Function 渲染的页面 —— checks.mjs 只扫 dist,这里靠同一套纪律手工维持:
// 不写 <script>、不用禁用说法、App Store 链接必带 pt+ct)。
// 样式是 global.css 设计 token 的最小子集内联(Function 页面不经过 Astro
// 构建,CSS 无法走 inlineStylesheets 管线;token 值改动需两处同步)。
import { siteConfig, siteUrl, appStoreUrl } from '../../src/config.mjs';

const PAGE_CSS = `
:root{--paper:#fbfaf7;--card:#fff;--ink:#1b2430;--ink-soft:#4d5a68;--ink-faint:#5f6b78;
--line:#e7e4dc;--accent:#177e4b;--accent-soft:#e6f4ec;--danger:#b3362b;
--radius:14px;--shadow:0 1px 2px rgba(27,36,48,.05),0 8px 24px rgba(27,36,48,.06);
--font:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,'Helvetica Neue',Arial,'Noto Sans',sans-serif}
*{box-sizing:border-box}
body{margin:0;font-family:var(--font);color:var(--ink);background:var(--paper);line-height:1.65;font-size:17px}
main{display:block;min-height:60vh}
.wrap{max-width:720px;margin:0 auto;padding:0 24px}
h1{font-size:clamp(1.6rem,4vw,2.2rem);font-weight:800;line-height:1.2;letter-spacing:-.015em;margin:0 0 12px}
h2{font-size:1.25rem;font-weight:700;margin:28px 0 10px}
.tp-header{border-bottom:1px solid var(--line);background:var(--card)}
.tp-header .wrap{display:flex;align-items:center;gap:10px;padding-top:14px;padding-bottom:14px}
.tp-mark{display:inline-block;width:26px;height:26px;border-radius:6px;background:var(--accent);color:#fff;font-size:17px;line-height:26px;text-align:center;font-weight:800}
.tp-brand{font-weight:700;text-decoration:none;color:var(--ink)}
.back{display:inline-block;margin:28px 0 8px;color:var(--accent);text-decoration:none;font-size:.95rem}
.card{border:1px solid var(--line);box-shadow:var(--shadow);border-radius:var(--radius);background:var(--card);padding:20px 22px;margin:14px 0}
.you-said{color:var(--ink-soft);font-style:italic;margin:0 0 6px}
.todo-row{display:flex;flex-wrap:wrap;gap:6px 14px;align-items:baseline;padding:11px 0;border-top:1px solid var(--line)}
.todo-row:first-of-type{border-top:0}
.todo-title{font-weight:600;flex:1 1 200px}
.todo-when{color:var(--ink-faint);font-size:.95rem}
.chip{display:inline-block;background:var(--accent-soft);border-radius:999px;padding:1px 12px;font-size:.9rem;color:var(--ink)}
.date-list{margin:0;padding:0;list-style:none}
.date-list li{padding:9px 0;border-top:1px solid var(--line)}
.date-list li:first-child{border-top:0}
.rule-text{font-size:1.15rem;font-weight:700;color:var(--accent);margin:4px 0 12px}
.copy-box{width:100%;min-height:110px;border:1px solid var(--line);border-radius:10px;padding:12px;font:inherit;color:var(--ink-soft);background:var(--card);resize:vertical}
.note{color:var(--ink-faint);font-size:.92rem}
.err{border-left:4px solid var(--danger);padding-left:14px}
.cta{margin:40px 0 0;padding:26px 0 30px;border-top:1px solid var(--line);text-align:center}
.cta p{margin:6px 0 0}
.store{display:inline-flex;align-items:center;gap:10px;background:#000;color:#fff;text-decoration:none;border-radius:10px;padding:8px 16px;margin-top:12px}
.store small{display:block;font-size:.62rem;opacity:.8}
.store strong{display:block;font-size:1rem;line-height:1.1}
.tp-foot{color:var(--ink-faint);font-size:.85rem;text-align:center;padding:26px 0 34px}
`;

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

/// 结果/错误页 HTML 壳。toolPath = 所属工具页(返回链接 + canonical 指向它),
/// ct = App Store 来源参数(结果页 CTA 的归因,与全站 appStoreUrl 约定一致)。
export function toolResultPage({ toolPath, toolLabel, heading, bodyHtml, ct }) {
  const year = new Date().getFullYear();
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(heading)} | ${siteConfig.appName}</title>
<meta name="description" content="Result page for the ${siteConfig.appName} ${escapeHtml(toolLabel)} tool.">
<meta name="robots" content="noindex">
<link rel="canonical" href="${siteUrl}${toolPath}">
<meta name="theme-color" content="#fbfaf7">
<link rel="icon" type="image/svg+xml" href="/favicon.svg">
<style>${PAGE_CSS}</style>
</head>
<body>
<header class="tp-header"><div class="wrap">
  <span class="tp-mark" aria-hidden="true">✓</span>
  <a class="tp-brand" href="/">${siteConfig.appName}</a>
</div></header>
<main>
  <div class="wrap">
    <a class="back" href="${toolPath}">← Back to the tool</a>
    <h1>${escapeHtml(heading)}</h1>
    ${bodyHtml}
  </div>
  <div class="wrap">
    <section class="cta">
      <h2 style="margin-top:0">Want this on your iPhone?</h2>
      <p class="note">The app does everything this page does — with reminders, repeats, widgets and Siri.</p>
      <a class="store" href="${appStoreUrl(ct)}" rel="noopener">
        <svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true" fill="#fff"><path d="M17.05 12.54c.02-2.2 1.79-3.26 1.87-3.31-1.02-1.5-2.61-1.7-3.17-1.73-1.35-.1-2.63.79-3.31.79-.69 0-1.74-.77-2.86-.75-1.47.02-2.83.86-3.59 2.17-1.53 2.67-.39 6.62 1.11 8.79.73 1.06 1.6 2.24 2.75 2.2 1.1-.04 1.52-.71 2.85-.71 1.33 0 1.7.71 2.87.69 1.19-.02 1.95-1.08 2.68-2.14.84-1.22 1.19-2.4 1.21-2.46-.03-.01-2.33-.9-2.36-3.54zM14.9 5.87c.6-.73 1.01-1.75.9-2.76-.87.04-1.92.58-2.55 1.31-.56.65-1.05 1.68-.92 2.67.97.08 1.96-.49 2.57-1.22z"></path></svg>
        <span><small>Download on the</small><strong>App Store</strong></span>
      </a>
      <p class="note">Free to start. Requires iPhone with iOS 26 or later.</p>
    </section>
  </div>
</main>
<footer class="tp-foot">&copy; ${year} ${siteConfig.appName}</footer>
</body>
</html>`;
}

export function htmlResponse(html, status = 200) {
  return new Response(html, {
    status,
    headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' },
  });
}

export { escapeHtml };

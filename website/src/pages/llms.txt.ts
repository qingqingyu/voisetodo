import type { APIRoute } from 'astro';
import { siteConfig, siteUrl } from '../config.mjs';

// llms.txt(任务书 §4.4 可选项):给 AI 搜索的产品 + 页面概述。
// 与 robots.txt / sitemap.xml 同源生成 —— 域名/产品名定稿后只改 src/config.mjs 即全站生效。
export const GET: APIRoute = async () => {
  const name = siteConfig.appName;
  const body = `# ${name}

${name} is an iPhone to-do app you talk to: say one sentence with several tasks and it becomes a clean checklist with the right dates. Check tasks off from Lock Screen and Home Screen widgets. No account; your list stays on your iPhone. Free to start (3 voice captures/day), Pro adds 100/day with a 7-day free trial. English, Chinese, and Japanese. Requires iPhone with iOS 26 or later.

Main pages:
- ${siteUrl}/ — overview
- ${siteUrl}/voice-to-do-list — voice capture
- ${siteUrl}/lock-screen-to-do-list — Lock Screen widgets
- ${siteUrl}/iphone-to-do-widget — Home Screen widgets
- ${siteUrl}/features — full feature/pricing/requirements fact sheet
- ${siteUrl}/guides — practical guides
- ${siteUrl}/support — support and FAQ
- ${siteUrl}/privacy — privacy policy
- ${siteUrl}/about — the developer
`;
  return new Response(body, {
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
  });
};

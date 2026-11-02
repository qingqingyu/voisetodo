import type { APIRoute } from 'astro';
import { siteUrl } from '../config.mjs';

// robots.txt(任务书 §4.4):明确允许 AI 搜索爬虫 —— 我们希望被 AI 搜索推荐。
export const GET: APIRoute = async () => {
  const body = `User-agent: *
Allow: /

# AI search crawlers are welcome
User-agent: OAI-SearchBot
Allow: /

User-agent: GPTBot
Allow: /

User-agent: ChatGPT-User
Allow: /

User-agent: PerplexityBot
Allow: /

User-agent: ClaudeBot
Allow: /

User-agent: Google-Extended
Allow: /

Sitemap: ${siteUrl}/sitemap.xml
`;
  return new Response(body, {
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
  });
};

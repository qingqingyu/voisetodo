import type { APIRoute } from 'astro';
import { getCollection } from 'astro:content';
import { siteUrl } from '../config.mjs';
import { pages } from '../data/pages.mjs';

// sitemap.xml(任务书 §4.4):含 lastmod;排除 404 与草稿指南(草稿 noindex,不进 sitemap)。
export const GET: APIRoute = async () => {
  const guides = (await getCollection('guides')).filter((g) => !g.data.draft);

  const staticEntries = Object.entries(pages)
    .filter(([, p]) => !p.noSitemap)
    .map(([path, p]) => ({
      loc: `${siteUrl}${path === '/' ? '/' : path}`,
      lastmod: p.lastmod,
      changefreq: p.changeFrequency,
      priority: p.priority,
    }));

  const guideEntries = guides.map((g) => ({
    loc: `${siteUrl}/guides/${g.id}`,
    lastmod: (g.data.updatedDate ?? g.data.pubDate).toISOString().slice(0, 10),
    changefreq: 'monthly',
    priority: 0.6,
  }));

  const xml = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${[...staticEntries, ...guideEntries]
  .map(
    (e) => `  <url>
    <loc>${e.loc}</loc>
    <lastmod>${e.lastmod}</lastmod>
    <changefreq>${e.changefreq}</changefreq>
    <priority>${e.priority.toFixed(1)}</priority>
  </url>`
  )
  .join('\n')}
</urlset>`;

  return new Response(xml, {
    headers: { 'Content-Type': 'application/xml; charset=utf-8' },
  });
};

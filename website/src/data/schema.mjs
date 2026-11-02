// JSON-LD 构建器(任务书 §4.3)。纯函数,返回可 JSON.stringify 的对象。
import { siteConfig, siteUrl } from '../config.mjs';

/**
 * JSON-LD → 内嵌 <script> 的安全序列化:把 `<` 替换为 JSON 六字符转义,
 * 防内容(title/FAQ 答案等)含 `</script>` 或 `<` 时破坏 HTML。
 * JSON.parse 还原后与原对象等价,checks.mjs 校验不受影响。
 */
export function jsonLdHtml(schema) {
  return JSON.stringify(schema).replace(/</g, '\\u003c');
}

export function ogImagePath(path) {
  const slug = path === '/' ? 'home' : path.replace(/^\//, '').replace(/\//g, '-');
  return `/og/${slug}.png`;
}

/** 全站:WebSite + Organization(独立开发者用 Organization 承载应用主体)。 */
export function webSiteSchema() {
  return {
    '@context': 'https://schema.org',
    '@type': 'WebSite',
    name: siteConfig.appName,
    url: siteUrl,
  };
}

export function organizationSchema() {
  return {
    '@context': 'https://schema.org',
    '@type': 'Organization',
    name: siteConfig.appName,
    url: siteUrl,
    logo: `${siteUrl}/apple-touch-icon.png`,
  };
}

/** 首页与 /features:MobileApplication(offers 价格 0 + 内购说明,§4.3)。 */
export function mobileAppSchema() {
  return {
    '@context': 'https://schema.org',
    '@type': 'MobileApplication',
    name: siteConfig.appName,
    operatingSystem: 'iOS 26 or later',
    applicationCategory: 'ProductivityApplication',
    inLanguage: 'en',
    url: siteUrl,
    offers: {
      '@type': 'Offer',
      price: '0',
      priceCurrency: 'USD',
      description:
        'Free to start (3 voice captures per day). Pro subscription available with a 7-day free trial; prices vary by region.',
    },
  };
}

/** 含 FAQ 的页面(与页面可见内容一致,由 Faq.astro 同源传入)。 */
export function faqPageSchema(faqs) {
  return {
    '@context': 'https://schema.org',
    '@type': 'FAQPage',
    mainEntity: faqs.map((f) => ({
      '@type': 'Question',
      name: f.q,
      acceptedAnswer: { '@type': 'Answer', text: f.a },
    })),
  };
}

/** 指南文章(Article)。 */
export function articleSchema(guide, ogUrl) {
  return {
    '@context': 'https://schema.org',
    '@type': 'Article',
    headline: guide.data.title,
    description: guide.data.description,
    inLanguage: 'en',
    datePublished: guide.data.pubDate.toISOString(),
    dateModified: (guide.data.updatedDate ?? guide.data.pubDate).toISOString(),
    image: ogUrl,
    author: { '@type': 'Person', name: `The ${siteConfig.appName} developer` },
    publisher: { '@type': 'Organization', name: siteConfig.appName },
  };
}

/** 二级页 BreadcrumbList。items: [{ name, path }] */
export function breadcrumbSchema(items) {
  return {
    '@context': 'https://schema.org',
    '@type': 'BreadcrumbList',
    itemListElement: items.map((item, i) => ({
      '@type': 'ListItem',
      position: i + 1,
      name: item.name,
      item: `${siteUrl}${item.path}`,
    })),
  };
}

/**
 * hreflang 备选链接(任务书 §4.1 多语言预留)。
 * 只有一种语言时返回空数组(不输出任何 <link rel="alternate">);
 * 加入 'ja' / 'zh' 后自动生成。路径约定:英文在根,其他语言带 /ja /zh 前缀。
 */
export function hreflangAlternates(path) {
  if (siteConfig.locales.length < 2) return [];
  return siteConfig.locales.map((loc) => {
    const prefix = loc === 'en' ? '' : `/${loc}`;
    // 首页:en 保持与 canonical 一致的尾斜杠(siteUrl + '/'),
    // 其他语言首页是 /ja、/zh 这种无尾斜杠路径,与全站 URL 约定一致。
    const home = path === '/' ? (loc === 'en' ? '/' : '') : path;
    return { hreflang: loc, href: `${siteUrl}${prefix}${home}` };
  });
}

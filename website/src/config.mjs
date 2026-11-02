// 网站占位符配置 —— 任务书 §0.1:所有未定产品决策集中在此,定下来后改一处全站生效。
// 修改任何值后重新 `npm run build` 即可;不要在页面里散落硬编码。
export const siteConfig = {
  // {{APP_NAME}} —— 产品名未定(VoiceTodo / Unpile 二选一),定稿后改这里。
  appName: 'VoiceTodo',

  // {{DOMAIN}} —— 域名未买;定稿后改这里(canonical / sitemap / robots / OG 全部随之更新)。
  domain: 'voicetodo.example.com',

  // {{APP_STORE_ID}} —— App Store 数字 ID,上架后填(apple-itunes-app 横幅与商店链接都用它)。
  appStoreId: '000000000',

  // {{PROVIDER_TOKEN}} —— App Store Connect 来源参数 pt(App 分析按页归因下载)。
  providerToken: 'PROVIDER_TOKEN',

  // {{SUPPORT_EMAIL}} —— 技术支持邮箱(support / privacy 两页使用)。
  supportEmail: 'support@example.com',

  // 多语言预留(任务书 §4.1):本次只做英文。加入 'ja' / 'zh' 后,
  // Base 布局的 hreflang 生成逻辑自动开始输出 <link rel="alternate">。
  locales: ['en'],
};

export const siteUrl = `https://${siteConfig.domain}`;

// App Store 落地链接(任务书 §4.7):全站商店链接必须经 appStoreUrl(ct) 生成,
// 构建检查脚本会校验每个商店链接都带 pt + ct 来源参数。
export function appStoreUrl(ct) {
  return `https://apps.apple.com/app/id${siteConfig.appStoreId}?pt=${siteConfig.providerToken}&ct=${ct}`;
}

export const appStoreBase = `https://apps.apple.com/app/id${siteConfig.appStoreId}`;

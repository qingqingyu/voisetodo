# VoiceTodo Website

英文产品官网,纯静态、零客户端 JS(Astro 输出纯 HTML;交互仅 `<details>` 等 HTML 原生能力)。
技术任务书:`docs/task-seo-website.md`;页面内容规格:`docs/task-seo-website-pages.md`。

## 本地开发

```bash
cd website
npm install
npm run dev        # 开发服务器
npm run build      # astro build + OG 图生成 + 验收检查(检查不过=构建失败)
npm run preview    # 本地预览 dist(gzip + Cache-Control,口径对齐 Cloudflare Pages)
npm run lighthouse # 移动端 Lighthouse(首页/功能页断言阈值,指南页仅报告,见下)
```

## 占位符(改一处全站生效)

全部在 `src/config.mjs`:产品名、域名、App Store ID、pt 来源令牌、支持邮箱。
定稿后只改这一个文件再构建。`src/data/pages.mjs` 是页面 title/description/FAQ 的单一来源。
**例外**:`src/content/legal/privacy.md` 是原样迁移的隐私政策(条款不得改动),
其中的联系邮箱来自源文件、不读取 config —— `SUPPORT_EMAIL` 定稿时需手动同步该文件(3 处)。

## 截图

`public/screens/*.webp` 由 `npm run images` 从仓库根 `screenshots/en/*.png` 生成(双档 640/1100),
并同步生成 `src/data/screens.mjs`(宽高数据,`<img>` 的 width/height 用,零 CLS)。
源截图更新后重跑 `npm run images`(按 mtime 幂等)。
**待补真机截图清单见结果文档**(锁屏三样式、桌面中/大、Siri/Action Button、设置步骤)。

## Lighthouse 口径(§4.5)

阈值:Performance ≥95 / SEO 100 / Accessibility ≥95 / Best Practices ≥95,移动端。
`npm run lighthouse` 对首页与 `/features` 断言阈值;指南页因是**草稿(noindex)**只报告
(「Page isn't indexed」审计必然扣 SEO 分;产品负责人审改后把 frontmatter `draft` 翻 `false`
即恢复正常断言)。**本机跑分注意**:Lighthouse 有 4x CPU 节流,机器有别的重负载
(如 Xcode/模拟器)时 TBT/主线程指标失真,得在空闲机器上取数。

## 部署到 Cloudflare Pages(不在本任务内执行)

1. Cloudflare Pages → Create project → Connect to Git repo(`voisetodo`),**Root directory: `website`**,
   Build command: `npm run build`,Output directory: `dist`。Node 版本环境变量 `NODE_VERSION=20`+。
   (Linux 构建机上 OG 图栅格化依赖系统字体,fontconfig 缺字体会导致文字变豆腐块——
   build 时如果 OG 图无文字,在构建命令前装字体,如 `apt-get install -y fonts-noto-core`
   或改用带 `loadSystemFonts` 的自带字体文件。)
2. 域名:买好后填入 `src/config.mjs` 的 `domain`,Pages 项目绑定该自定义域名。
   canonical/sitemap/robots/OG/llms.txt 全部自动跟随。
3. 旧隐私页跳转:GitHub Pages(qingqingyu.github.io/voicetodo-privacy)加 301 到新站 `/privacy`
   (GitHub Pages 用 `_redirects` 不生效,需在页面 head 加 canonical + meta refresh,或改用
   Cloudflare Redirect Rules)。
4. App Store Connect:「技术支持网址」填 `https://<domain>/support`;
   App「营销网址」可填 `https://<domain>/`。
5. `pt` 来源参数:ASC App 分析需与官方 Provider Token(affiliation)关联才能看到归因——
   在 ASC 用户与访问 → 生成/查看 Provider Token,替换 `src/config.mjs` 的 `providerToken`。
   页面标识(`ct`)全站已按 `web-nav / web-home-hero / web-voice-footer …` 打点,可直接在
   ASC App 分析按来源分页看下载。

## 上线后接入(§4.4)

- **Google Search Console**:资源类型=网域(买域名后 DNS 验证),提交 `sitemap.xml`。
- **Bing Webmaster Tools**:GSC 一键导入(ChatGPT 搜索大量依赖必应索引)。
- **IndexNow / Crawler Hints**:Cloudflare Dashboard → 该域名 → Caching → 开 Crawler Hints
  (Pages 项目自动接入,无需手动 ping)。

## 每月度量(§7)

| 看哪 | 回答什么 |
|---|---|
| Search Console:§2 关键词组的曝光/点击/排名 | 哪些页面有曝光没点击 → 改 title/description |
| ASC App 分析:按 `ct` 分页的下载 | 哪个页面带量;有点击没下载 → 改页面内容 |
| Cloudflare Web Analytics(无 Cookie,已预留,部署时开启即可) | 访问量与热门路径 |

## 多语言(预留,未启用)

`src/config.mjs` 的 `locales` 目前只有 `en`。加 `'ja'`/`'zh'` 后:

1. `Base.astro` 的 hreflang 生成器自动开始输出 `<link rel="alternate">`(已验证单语言时静默);
2. 按约定把各语言页面放进 `/ja/`、`/zh/` 前缀路径;
3. `sitemap.xml` 需同步把各语言 URL 加进清单(目前只列英文)。

## 指南草稿工作流

指南 markdown 在 `src/content/guides/`,`draft: true` = 页面带「Draft — pending review」
徽章 + noindex + 不进 sitemap。产品负责人逐篇审改后把 `draft` 翻 `false` 提交即发布。

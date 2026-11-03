import { defineConfig } from 'astro/config';
import { siteUrl } from './src/config.mjs';

// 纯静态输出(任务书 §4.1):零客户端 JS,Astro 默认不上岛。
// URL 全站无尾斜杠:build.format='file' 产 /foo.html,Cloudflare Pages 以 /foo 提供。
export default defineConfig({
  site: siteUrl,
  output: 'static',
  trailingSlash: 'never',
  build: {
    format: 'file',
    // ~12KB CSS 全部内联:零渲染阻塞请求(LCP 友好;静态站每页重复这点体积可接受)
    inlineStylesheets: 'always',
  },
});

// 极简静态文件服务器(本地预览 + Lighthouse 用,零依赖)。
// CLI:node scripts/serve.mjs <root> <port>;模块:createStaticServer(root)。
// gzip + Cache-Control 与 Cloudflare Pages 默认行为对齐,保证本地 Lighthouse 口径不失真。
import http from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { createGzip } from 'node:zlib';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.xml': 'application/xml; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.webp': 'image/webp',
  '.ico': 'image/x-icon',
};

const COMPRESSIBLE = new Set(['.html', '.css', '.js', '.json', '.xml', '.txt', '.svg']);

async function serveBuffer(req, res, file, data, status = 200) {
  const ext = path.extname(file) || '.html';
  const type = MIME[ext] ?? 'application/octet-stream';
  // 只认十六进制哈希后缀(-a1b2c3d4.ext);宽字符组会把 'xx-recording-640'、
  // 'plan-your-day-in-2-minutes' 这类连字符命名误判成哈希文件而发 immutable。
  const hashed = /-[A-Fa-f0-9]{8,}\.[a-z]+$/.test(path.basename(file));
  const headers = {
    'Content-Type': type,
    // 带内容哈希的文件可一年;HTML/无哈希走协商(Cache-Control: no-cache 语义)
    'Cache-Control': hashed ? 'public, max-age=31536000, immutable' : COMPRESSIBLE.has(ext) ? 'public, max-age=0' : 'public, max-age=3600',
  };
  if (COMPRESSIBLE.has(ext) && /\bgzip\b/.test(req.headers['accept-encoding'] ?? '')) {
    headers['Content-Encoding'] = 'gzip';
    res.writeHead(status, headers);
    data.pipe(createGzip()).pipe(res);
  } else {
    // data 是 ReadStream(无 .length)——Content-Length 必须从 stat 取,
    // 否则 writeHead 收到 undefined 抛错,外层 catch 会把所有图片吞成 404。
    const { size } = await stat(file);
    headers['Content-Length'] = size;
    res.writeHead(status, headers);
    data.pipe(res);
  }
}

export function createStaticServer(root) {
  const rootResolved = path.resolve(root);
  return http.createServer(async (req, res) => {
    try {
      const urlPath = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
      let file = path.normalize(path.join(rootResolved, urlPath));
      // 防目录逃逸:URL 规范化在解码之前,%2e%2e%2f 解码后可引入 ../
      if (file !== rootResolved && !file.startsWith(rootResolved + path.sep)) {
        throw new Error('path escapes root');
      }
      if (urlPath.endsWith('/')) file = path.join(file, 'index.html');
      let target = file;
      try {
        await readFile(target);
      } catch {
        // 无后缀 → 试 .html(与 Cloudflare Pages 的 clean URL 行为一致)
        if (!path.extname(file)) {
          try {
            target = file + '.html';
            await readFile(target);
          } catch {
            target = path.join(rootResolved, '404.html');
            await readFile(target);
            await serveBuffer(req, res, target, (await import('node:fs')).createReadStream(target), 404);
            return;
          }
        } else {
          throw new Error('not found');
        }
      }
      const { createReadStream } = await import('node:fs');
      await serveBuffer(req, res, target, createReadStream(target));
    } catch {
      // catch 内不得再抛(否则未处理拒绝崩进程):响应已开头则断开连接
      if (res.headersSent) res.destroy();
      else {
        res.writeHead(404, { 'Content-Type': 'text/plain' });
        res.end('Not found');
      }
    }
  });
}

// CLI 模式
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const { stat } = await import('node:fs/promises');
  const root = path.resolve(process.argv[2] ?? 'dist');
  const port = Number(process.argv[3] ?? 4173);
  await stat(root);
  createStaticServer(root).listen(port, () => {
    console.log(`Serving ${root} at http://localhost:${port}/`);
  });
}

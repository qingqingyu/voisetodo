// website/wrangler.toml 的关键配置守卫(Pages 直传部署的配置唯一来源)。
// 背景:2026-11-23 排障发现缺 enable_request_signal 时,代理侧整套断连退款
// 空转;漏写 [vars].AI_PROXY_ORIGIN 时工具① 线上直接 503。这些都发生在
// 「配置在面板、仓库看不见」的盲区 —— 本测试把关键项钉进 CI 口径。
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFile } from 'node:fs/promises';

const toml = await readFile(new URL('../../wrangler.toml', import.meta.url), 'utf-8');

test('Pages 项目名与产物目录已声明(直传部署的配置来源)', () => {
  assert.match(toml, /^name = "voicetodo-app"$/m);
  assert.match(toml, /^pages_build_output_dir = "\.\/dist"$/m);
});

test('断连信号标志必须在(兼容日期 < 2026-11-17 时缺失 = 断连退款空转)', () => {
  assert.match(toml, /^compatibility_flags = \["enable_request_signal"\]$/m);
  assert.match(toml, /^compatibility_date = "20\d\d-\d\d-\d\d"$/m);
});

test('工具① 的非机密变量必须在([vars] 是直传部署纯文本变量的唯一来源)', () => {
  assert.match(toml, /^AI_PROXY_ORIGIN = "https:\/\/ai\.saydo\.org"$/m);
});

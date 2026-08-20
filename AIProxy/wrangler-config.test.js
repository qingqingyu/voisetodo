// 部署配置断言。
//
// 为什么需要它:worker.test.js 里所有测试都注入内联 `env` 对象,从不读真正部署的
// wrangler.toml。于是「代码正确 + 测试全绿 + 线上配置漏了一个 var」可以长期共存 ——
// 这正是 PAID_DAILY_LIMIT 缺失导致 Pro 订阅完全无效却没人发现的原因:
// resolveSubscriptionTier 里 hasPaidLimit 为 false 时直接返回 free 档,连 JWS 都不验签,
// 付费用户和免费用户拿到完全相同的额度,而 paywall 仍在承诺更高额度。
// (worker.test.js 的 "Pro JWS raises tier to paid limit" 一直是绿的 —— 因为它自己注入了
//  PAID_DAILY_LIMIT。代码从来没错,错的是部署配置。)
//
// 这组断言只校验「测试阶段和上线之后都必须成立」的不变量,不锁具体数值 ——
// 数值本身会随阶段调整(见 CONFIGURATION_CHECKLIST.md)。

import assert from "node:assert/strict";
import { test } from "node:test";
import { readFileSync } from "node:fs";

// 极简 TOML `[vars]` 解析器:只认 `KEY = "value"` 这一种形态,足够覆盖额度配置。
// 必须正确跳过 PROVIDERS 的 ''' 多行字符串 —— 否则块内独立成行的 `[` 会被误判成
// 新 section,导致 [vars] 提前结束、块之后的 var 全部读不到。
export function parseVars(text) {
  const vars = {};
  let inVars = false;
  let inMultiline = false;

  for (const rawLine of text.split("\n")) {
    const line = rawLine.trim();

    if (inMultiline) {
      if (line.endsWith("'''")) inMultiline = false;
      continue;
    }
    if (line === "" || line.startsWith("#")) continue;

    // section 头。`[[kv_namespaces]]` 之类同样在此终止 [vars]。
    if (line.startsWith("[")) {
      inVars = line === "[vars]";
      continue;
    }
    if (!inVars) continue;

    // 多行字符串起始:`KEY = '''`(除非同一行就闭合)
    const multilineStart = line.match(/^([A-Z0-9_]+)\s*=\s*'''(.*)$/);
    if (multilineStart) {
      if (!multilineStart[2].trim().endsWith("'''")) inMultiline = true;
      continue;
    }

    const match = line.match(/^([A-Z0-9_]+)\s*=\s*"([^"]*)"/);
    if (match) vars[match[1]] = match[2];
  }
  return vars;
}

function readVars(path) {
  return parseVars(readFileSync(path, "utf8"));
}

const CONFIGS = [
  { label: "wrangler.toml (deployed)", path: new URL("./wrangler.toml", import.meta.url) },
  { label: "wrangler.toml.example", path: new URL("./wrangler.toml.example", import.meta.url) }
];

for (const { label, path } of CONFIGS) {
  test(`${label}: DAILY_REQUEST_LIMIT and PAID_DAILY_LIMIT are both present`, () => {
    const vars = readVars(path);

    assert.ok(
      vars.DAILY_REQUEST_LIMIT !== undefined,
      "DAILY_REQUEST_LIMIT 缺失 → enforceDailyLimit 直接 skip,配额完全不生效(fail-open)"
    );
    assert.ok(
      vars.PAID_DAILY_LIMIT !== undefined,
      "PAID_DAILY_LIMIT 缺失 → resolveSubscriptionTier 的 hasPaidLimit 为 false,"
        + "所有 Pro 用户被当免费档处理、JWS 不验签,付费无任何权益差异"
    );
  });

  test(`${label}: both daily limits are positive integers`, () => {
    const vars = readVars(path);

    for (const key of ["DAILY_REQUEST_LIMIT", "PAID_DAILY_LIMIT"]) {
      const value = Number(vars[key]);
      assert.ok(
        Number.isInteger(value) && value > 0,
        `${key}="${vars[key]}" 不是正整数 → worker 侧 Number.isFinite 校验会判为无效并跳过配额`
      );
    }
  });

  test(`${label}: PAID_DAILY_LIMIT is strictly greater than DAILY_REQUEST_LIMIT`, () => {
    const vars = readVars(path);
    const free = Number(vars.DAILY_REQUEST_LIMIT);
    const paid = Number(vars.PAID_DAILY_LIMIT);

    assert.ok(
      paid > free,
      `PAID_DAILY_LIMIT (${paid}) 必须严格大于 DAILY_REQUEST_LIMIT (${free})。`
        + "两者相等意味着订阅不带来任何额度提升,paywall 的承诺无法兑现;"
        + "上线时这两个值必须成对修改(见 CONFIGURATION_CHECKLIST.md)"
    );
  });

  test(`${label}: subscription JWS verification vars are present`, () => {
    const vars = readVars(path);

    assert.ok(
      typeof vars.APP_BUNDLE_ID === "string" && vars.APP_BUNDLE_ID.length > 0,
      "APP_BUNDLE_ID 缺失 → worker.js 回退默认值 com.voicetodo.app,与本 app 的"
        + " bundle 不匹配 → verifySubscriptionJWS 抛 bundle_mismatch → fail-safe 免费档,"
        + "已订阅用户被静默降级(免费额度 + 撞墙弹升级 paywall)"
    );
    const proIDs = String(vars.PRO_PRODUCT_IDS || "")
      .split(",").map((s) => s.trim()).filter(Boolean);
    assert.ok(
      proIDs.length >= 1 && proIDs.every((id) => /^[\w.]+$/.test(id)),
      `PRO_PRODUCT_IDS="${vars.PRO_PRODUCT_IDS}" 不是非空的逗号分隔产品 ID 列表 → `
        + "worker.js 回退默认值 com.voicetodo.pro.* → 真实订阅验签抛 product_mismatch → 免费档"
    );
  });
}

// MARK: - 订阅验签值必须与 iOS 端逐字一致(仅校验真正部署的 wrangler.toml)
//
// 为什么交叉校验 iOS 源码:APP_BUNDLE_ID / PRO_PRODUCT_IDS 的正确值定义在
// iOS 仓库(project.yml / EntitlementManager.swift),不在本目录。只断言「存在」
// 防不住「iOS 端改了产品 ID / bundle 而忘了同步 toml」—— 那正是
// 2026-08-20 订阅用户被降级 bug 的形态:两个默认值都存在但全错。

function swiftProductIDConstant(name) {
  const source = readFileSync(new URL("../App/EntitlementManager.swift", import.meta.url), "utf8");
  const match = source.match(new RegExp(`static\\s+let\\s+${name}\\s*=\\s*"([^"]+)"`));
  return match ? match[1] : null;
}

function mainAppBundleID() {
  const source = readFileSync(new URL("../project.yml", import.meta.url), "utf8");
  // 兼容带引号/不带引号两种 yml 合法写法,剥掉成对引号避免断言误报。
  const ids = [...source.matchAll(/PRODUCT_BUNDLE_IDENTIFIER:\s*"?([^\s"]+)"?/g)].map((m) => m[1]);
  if (ids.length === 0) return null;
  // 主 app target 的 bundle ID 是所有 target(.widget/.tests/.uitests)的前缀,
  // 取最短的即主 app。
  return ids.reduce((shortest, id) => (id.length < shortest.length ? id : shortest));
}

test("wrangler.toml: subscription verification vars match the iOS client", () => {
  const vars = readVars(DEPLOYED);

  const monthly = swiftProductIDConstant("monthlyProductID");
  const yearly = swiftProductIDConstant("yearlyProductID");
  assert.ok(monthly && yearly, "App/EntitlementManager.swift 解析不到 monthlyProductID/yearlyProductID —— 正则过期了?");
  const bundle = mainAppBundleID();
  assert.ok(bundle, "project.yml 解析不到 PRODUCT_BUNDLE_IDENTIFIER —— 正则过期了?");

  const proIDs = String(vars.PRO_PRODUCT_IDS).split(",").map((s) => s.trim()).filter(Boolean);
  assert.ok(
    proIDs.includes(monthly) && proIDs.includes(yearly),
    `PRO_PRODUCT_IDS (${vars.PRO_PRODUCT_IDS}) 未同时包含 iOS 端的 "${monthly}" 与 "${yearly}"。`
      + "改产品 ID 必须两边同步改,否则验签永远 product_mismatch,付费用户被降级到免费档"
  );
  assert.strictEqual(
    vars.APP_BUNDLE_ID,
    bundle,
    `APP_BUNDLE_ID 应为 project.yml 主 app target 的 "${bundle}"。`
      + "不一致 → 验签永远 bundle_mismatch,付费用户被降级到免费档"
  );
});

// MARK: - 超时预算:Worker 最坏 failover 耗时必须装得进 iOS 客户端的等待窗口

// `Protocols/Constants.swift` 的 NetworkConfig.apiTimeout。改那边必须改这里。
const IOS_API_TIMEOUT_SECONDS = 55;
// 同文件的 NetworkConfig.workerTailAllowance:最后一跳 TTFB + Worker 自身开销
// (KV / DO 往返、JWS 验签、isolate 冷启动)。
const TAIL_ALLOWANCE_SECONDS = 15;

// parseVars 会跳过 ''' 多行块,所以 PROVIDERS 需要单独读。
export function parseProviders(text) {
  const match = text.match(/^\s*PROVIDERS\s*=\s*'''\s*\n([\s\S]*?)\n\s*'''/m);
  if (!match) return null;
  return JSON.parse(match[1]);
}

// 只校验真正部署的 wrangler.toml:wrangler.toml.example 里 PROVIDERS 和
// AI_PROVIDER_MAX_ATTEMPTS 都是注释掉的模板,没有可校验的实际值。
const DEPLOYED = new URL("./wrangler.toml", import.meta.url);

test("wrangler.toml: AI_PROVIDER_MAX_ATTEMPTS is explicitly configured", () => {
  const vars = readVars(DEPLOYED);

  assert.ok(
    vars.AI_PROVIDER_MAX_ATTEMPTS !== undefined,
    "不显式配置时 resolveMaxAttempts 返回 undefined → 尝试全部候选。"
      + "新增第三个 provider 会让 Worker 最坏耗时静默增长,而 iOS 端的 apiTimeout 不会跟着变,"
      + "客户端会在 Worker 还在 failover 时断线,并把这次放弃当成一次服务故障喂给自己的熔断器"
  );
  const value = Number(vars.AI_PROVIDER_MAX_ATTEMPTS);
  assert.ok(Number.isInteger(value) && value > 0, `AI_PROVIDER_MAX_ATTEMPTS="${vars.AI_PROVIDER_MAX_ATTEMPTS}" 不是正整数`);
});

test("wrangler.toml: provider failover worst case fits inside the iOS client timeout budget", () => {
  const text = readFileSync(DEPLOYED, "utf8");
  const vars = parseVars(text);
  const providers = parseProviders(text);

  assert.ok(providers?.length, "PROVIDERS 解析失败");

  const maxAttempts = Math.min(Number(vars.AI_PROVIDER_MAX_ATTEMPTS), providers.length);
  // timeoutMs 选填,worker 侧默认 15_000。
  const maxTimeoutSeconds = Math.max(...providers.map((p) => Number(p.timeoutMs) || 15000)) / 1000;
  // executeWithFailover 串行走候选:前 (maxAttempts - 1) 个各自耗满 timeout 才轮到最后一个。
  const worstCase = (maxAttempts - 1) * maxTimeoutSeconds + TAIL_ALLOWANCE_SECONDS;

  assert.ok(
    worstCase <= IOS_API_TIMEOUT_SECONDS,
    `Worker 最坏 failover 耗时 ${worstCase}s 超过 iOS apiTimeout ${IOS_API_TIMEOUT_SECONDS}s。`
      + "失配会产生最隐蔽的一种失效:provider 1 挂满 timeout、Worker 正切到 provider 2 且注定"
      + "会成功,而客户端已经放弃并把 .apiTimeout 当成一次服务故障喂进熔断器 —— "
      + "用户看到降级,服务端日志里却是一次成功的 failover。"
      + "要么调小 timeoutMs / AI_PROVIDER_MAX_ATTEMPTS,要么同步调大 Protocols/Constants.swift 的 apiTimeout"
  );
});

// MARK: - 解析器自身的回归测试

test("parseVars keeps vars that follow a ''' multiline block", () => {
  const vars = parseVars(`
[vars]
DAILY_REQUEST_LIMIT = "2"
PROVIDERS = '''
[
  { "id": "A", "url": "https://example.com" }
]
'''
PAID_DAILY_LIMIT = "100"

[[kv_namespaces]]
binding = "RATE_LIMIT_KV"
`);

  assert.equal(vars.DAILY_REQUEST_LIMIT, "2");
  // 多行块里的 `[` 若被当成 section 头,这一行就读不到了
  assert.equal(vars.PAID_DAILY_LIMIT, "100");
  assert.equal(vars.PROVIDERS, undefined);
  // [[kv_namespaces]] 之后的 binding 不属于 [vars]
  assert.equal(vars.binding, undefined);
});

test("parseVars ignores commented-out vars", () => {
  const vars = parseVars(`
[vars]
# PAID_DAILY_LIMIT = "100"
DAILY_REQUEST_LIMIT = "2"
`);

  assert.equal(vars.DAILY_REQUEST_LIMIT, "2");
  assert.equal(
    vars.PAID_DAILY_LIMIT,
    undefined,
    "注释掉的 var 必须被当成缺失 —— 这正是 P0-2 的原始形态"
  );
});

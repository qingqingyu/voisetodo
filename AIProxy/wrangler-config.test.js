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
}

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

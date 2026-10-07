import { test, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { handleRequest, enforceRateLimits } from "./worker.js";

const APP_TOKEN = "test-token";
const realFetch = globalThis.fetch;
let telegramCalls;

beforeEach(() => {
  telegramCalls = 0;
  globalThis.fetch = async () => {
    telegramCalls += 1;
    return new Response(JSON.stringify({ ok: true }), { status: 200 });
  };
});

afterEach(() => {
  globalThis.fetch = realFetch;
});

// D1 替身:只认本 worker 用到的三种语句
function makeDb({ recentCount = 0, failCount = false } = {}) {
  const inserts = [];
  return {
    inserts,
    prepare(sql) {
      return {
        bind(...args) {
          return {
            async first() {
              if (failCount) throw new Error("d1 down");
              assert.match(sql, /COUNT\(\*\)/);
              return { n: recentCount };
            },
            async run() {
              if (sql.startsWith("INSERT")) {
                inserts.push(args);
                return { meta: { last_row_id: inserts.length } };
              }
              return { meta: {} };
            }
          };
        }
      };
    }
  };
}

function makeLimiter(allowed) {
  const keys = [];
  return {
    keys,
    async limit({ key }) {
      keys.push(key);
      return { success: allowed };
    }
  };
}

function makeEnv(overrides = {}) {
  return {
    APP_TOKEN,
    TELEGRAM_BOT_TOKEN: "bot",
    TELEGRAM_CHAT_ID: "1",
    FEEDBACK_DB: makeDb(),
    ...overrides
  };
}

function feedbackRequest({ token = APP_TOKEN, ip = "203.0.113.7" } = {}) {
  return new Request("https://feedback.example/v1/feedback", {
    method: "POST",
    headers: { "X-App-Token": token, "CF-Connecting-IP": ip, "Content-Type": "application/json" },
    body: JSON.stringify({ type: "bug", description: "录音按钮没反应" })
  });
}

test("正常反馈:归档 + 推送 + 200", async () => {
  const env = makeEnv();
  const res = await handleRequest(feedbackRequest(), env);
  assert.equal(res.status, 200);
  assert.equal(env.FEEDBACK_DB.inserts.length, 1);
  assert.equal(telegramCalls, 1);
});

test("单 IP 超限:429 scope=ip,不归档不推送", async () => {
  const limiter = makeLimiter(false);
  const env = makeEnv({ FEEDBACK_IP_LIMITER: limiter });
  const res = await handleRequest(feedbackRequest(), env);
  assert.equal(res.status, 429);
  assert.deepEqual(await res.json(), { error: "rate_limited", scope: "ip" });
  assert.deepEqual(limiter.keys, ["203.0.113.7"]);
  assert.equal(env.FEEDBACK_DB.inserts.length, 0);
  assert.equal(telegramCalls, 0);
});

test("全局每小时达上限(默认 30):429 scope=global", async () => {
  const env = makeEnv({ FEEDBACK_DB: makeDb({ recentCount: 30 }) });
  const res = await handleRequest(feedbackRequest(), env);
  assert.equal(res.status, 429);
  assert.equal((await res.json()).scope, "global");
  assert.equal(telegramCalls, 0);
});

test("全局未达上限放行;FEEDBACK_HOURLY_LIMIT 可覆盖默认值", async () => {
  assert.equal(await enforceRateLimits(feedbackRequest(), makeEnv({ FEEDBACK_DB: makeDb({ recentCount: 29 }) })), null);
  const env = makeEnv({ FEEDBACK_DB: makeDb({ recentCount: 5 }), FEEDBACK_HOURLY_LIMIT: "5" });
  assert.deepEqual(await enforceRateLimits(feedbackRequest(), env), { scope: "global" });
});

test("非法 FEEDBACK_HOURLY_LIMIT 回落默认值", async () => {
  for (const bad of ["", "  ", "0", "-3", "abc"]) {
    const env = makeEnv({ FEEDBACK_DB: makeDb({ recentCount: 29 }), FEEDBACK_HOURLY_LIMIT: bad });
    assert.equal(await enforceRateLimits(feedbackRequest(), env), null, `limit=${JSON.stringify(bad)}`);
  }
});

test("闸门故障 fail-open:limiter 抛错 / D1 计数抛错仍放行", async () => {
  const env = makeEnv({
    FEEDBACK_IP_LIMITER: { async limit() { throw new Error("binding down"); } },
    FEEDBACK_DB: makeDb({ failCount: true })
  });
  assert.equal(await enforceRateLimits(feedbackRequest(), env), null);
});

test("未绑定 limiter 也未配 D1:不限流(旧部署兼容)", async () => {
  const env = makeEnv({ FEEDBACK_DB: undefined });
  assert.equal(await enforceRateLimits(feedbackRequest(), env), null);
});

test("token 错误先于限流返回 401,不消耗 IP 配额", async () => {
  const limiter = makeLimiter(true);
  const env = makeEnv({ FEEDBACK_IP_LIMITER: limiter });
  const res = await handleRequest(feedbackRequest({ token: "wrong" }), env);
  assert.equal(res.status, 401);
  assert.equal(limiter.keys.length, 0);
});

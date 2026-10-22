// Provider failover executor.
//
// Walks the selector's candidate list in order, calling the right adapter for each.
// 候选列表的每个 element 是「条目」(selector.js 返回,携带 candidateKeys);
// 执行层负责条目内选 key(A1/A2):
//   - 配置了 maxConcurrencyPerKey 且闸门可用 → 闸门选在途最少的 key 并拿租约
//   - 否则随机选 key
//   - key 级失败(立即 429 忙/余额耗尽、401/403)→ 换同条目另一个 key 重试,
//     不消耗 AI_PROVIDER_MAX_ATTEMPTS(R4;上限 = 条目内可用 key 数)
//   - 条目级失败(超时/网络/5xx/model_config/响应无效)→ 按现有规则走条目级
//     failover,保护客户端 55s 超时预算
//
// Failure handling is split into two regimes:
//
//   - Build/fetch stage (before Response reaches the caller):
//     Any failure here is failover-eligible. Network errors / timeouts are always
//     retryable. Non-2xx responses are classified by adapter.isRetryable using
//     status + body keywords; non-retryable ones bubble up as 502 to the client
//     (the request body itself is bad — switching provider won't help).
//
//   - Body validation stage (after an HTTP 200):
//     The optional onResponse hook may validate a non-stream body or verify a stream
//     body exists before anything reaches the client. Hook failures are failover-
//     eligible while another candidate remains. Mid-stream failures after the caller
//     returns the Response still propagate through the ReadableStream.
//
// Health/circuit recording granularity (A1 R1,熔断按 key 记账,healthId = 条目id#序号):
//   - key 级失败(quota_exhausted / status_429 忙 / auth)→ 只记当前 key
//   - 条目级失败(超时/网络/5xx/model_config/invalid_response)→ 记条目全部可用 key
//     (同条目 key 共享同一后端,系统性故障该整条摘除,阈值语义与改前条目级一致)
//   - 成功 → 记当前 key(EWMA 延迟按 key 累积,selector 取条目内最小值)
//   - 流中途失败 → 记当前 key(死的是这条连接,不是所有 key)
//
// On success, returns { provider, adapter, response, bodyResult, attempts, lease,
// confirmSuccess, confirmFailure } — lease 是闸门租约:
//   - 非流式:body 已读完,executeWithFailover 内部已 release,lease=null
//   - 流式:所有权移交调用方(worker.js 把 release 挂进流的 onSettled)
// Exhausting retryable pre-body failures throws 503; a final pre-client body
// validation failure keeps its original 502. 所有 throw 路径由外层 finally 兜底 release。

import { getAdapter } from "./adapters/index.js";
import { ProxyHTTPError } from "./errors.js";
import { logInfo, logWarn, logError, errorFields, redactText } from "./log.js";

const MAX_PROVIDER_ERROR_BODY_BYTES = 64 * 1024;

// 非闸门路径的条目内 key 挑选。默认 Math.random;测试通过 _testSetKeyPickRandom
// 注入种子 RNG 获得可复现序列(生产不调用)。
let keyPickRandom = Math.random;

/// 测试专用:注入/重置 key 挑选 RNG。传 null 恢复 Math.random。
export function _testSetKeyPickRandom(fn) {
  keyPickRandom = fn || Math.random;
}

// key 级失败分类:换同条目另一个 key 有意义(问题只出在这把 key 上)。
// quota_exhausted(429 余额耗尽)、status_429(忙,立即返回)、auth(401/403)。
function isKeyScopedFailure(classification) {
  return classification.errorType === "quota_exhausted"
    || classification.errorType === "status_429"
    || classification.errorType === "auth";
}

// 条目的可用 key 列表。selector 产出的条目带 candidateKeys(熔断未开的);
// 直造/旧形状条目回退 keys[],再回退单 key 合成(healthId = 条目 id)。
function entryUsableKeys(entry) {
  if (Array.isArray(entry.candidateKeys) && entry.candidateKeys.length > 0) {
    return entry.candidateKeys;
  }
  if (Array.isArray(entry.keys)) {
    const withKey = entry.keys.filter((k) => k.apiKey);
    if (withKey.length > 0) return withKey;
  }
  if (entry.apiKey) {
    return [{ index: 0, secretName: entry.secretName, apiKey: entry.apiKey, healthId: entry.id }];
  }
  return [];
}

export async function executeWithFailover(candidates, params, fetchImpl, requestContext, options = {}) {
  if (!candidates.length) {
    logWarn("proxy.selector.empty", { ...requestContext });
    throw new ProxyHTTPError(503, "All providers unavailable");
  }

  const healthStore = options.healthStore || null;
  const onResponse = typeof options.onResponse === "function" ? options.onResponse : null;
  const gate = options.gate || null;
  const attempts = [];
  const stream = Boolean(params.stream);

  let activeLease = null;      // 当前持有的闸门租约(可能为 null:未配闸门/fail-open)
  let transferredLease = null; // 流式成功后所有权已移交流生命周期,finally 不再 release

  try {
    for (let index = 0; index < candidates.length; index++) {
      const entry = candidates[index];
      const adapter = getAdapter(entry.type);
      if (!adapter) {
        // config.js validates types against the registry, so this is a defensive guard.
        throw new ProxyHTTPError(500, `Unknown adapter for provider ${entry.id}`);
      }

      const usableKeys = entryUsableKeys(entry);
      if (usableKeys.length === 0) {
        // selector 已过滤无 key 条目;走到这里说明候选被绕过构造,防御性跳过。
        logWarn("proxy.provider.no_usable_key", { ...requestContext, providerId: entry.id });
        continue;
      }
      const hasNextEntry = index < candidates.length - 1;
      const untriedKeys = new Set(usableKeys);

      // ── 条目内 key 循环:key 级失败换 key 重试(R4),条目级失败跳出换条目 ──
      let advanceToNextEntry = false;
      while (untriedKeys.size > 0 && !advanceToNextEntry) {
        // 1) 选 key + 拿租约
        const remainingKeys = [...untriedKeys];
        let chosenKey;
        let lease = null;
        if (gate && gate.enabledFor(entry)) {
          const slot = await gate.acquireEntrySlot(entry, remainingKeys, { wait: !hasNextEntry });
          if (slot.full) {
            // 条目池满。无备选条目 → 503 + Retry-After(任务书 §2.2.4);
            // 有备选条目 → 立刻 failover(等待只发生在没有别处可去时,见 keyGate.js)。
            logWarn("proxy.gate.pool_full", {
              ...requestContext,
              providerId: entry.id,
              waited: !hasNextEntry,
              keySlots: usableKeys.length
            });
            if (!hasNextEntry) {
              // 带 body 走 worker 的 structured 错误分支 —— plain-text 分支不透传
              // error.headers,Retry-After 会丢(见 handleRequest 的 catch)。
              throw new ProxyHTTPError(503, "Provider key pool saturated", {
                headers: { "Retry-After": "2" },
                errorType: "key_pool_full",
                rateLimitType: "key_pool_full",
                body: { error: "key_pool_full", retryAfter: 2, message: "Provider key pool saturated, retry shortly" }
              });
            }
            advanceToNextEntry = true;
            break;
          }
          chosenKey = slot.key;
          lease = slot.lease || null; // fail-open 时 lease 为 null,直接放行
        } else {
          chosenKey = pickRandomKey(remainingKeys);
        }
        untriedKeys.delete(chosenKey);
        if (activeLease) {
          // 上一轮 key 级失败留下的租约:换 key 前先还(租约绑定具体 key 的名额)。
          await activeLease.release();
        }
        activeLease = lease;

        const provider = { ...entry, apiKey: chosenKey.apiKey };
        const attempt = {
          providerId: entry.id,
          providerType: entry.type,
          model: entry.model,
          keySlot: usableKeys.length > 1 ? `${entry.id}#${chosenKey.index}` : undefined,
          attempt: index + 1,
          startedAt: Date.now()
        };
        if (attempt.keySlot === undefined) delete attempt.keySlot;

        logInfo("proxy.provider.call_start", {
          ...requestContext,
          providerId: entry.id,
          provider: entry.type,
          model: entry.model,
          attempt: attempt.attempt,
          stream
        });

        const hasNext = hasNextEntry || untriedKeys.size > 0;
        let response = null;
        let responseError = null;

        // fetchStartedAt 在 try 外声明,catch 才能 access;null = 还没进 fetch 阶段
        // (buildRequest 已抛 invariant_violation 等)。fetch_done 只在 fetchStartedAt!==null 时打。
        let fetchStartedAt = null;
        try {
          const { url, init } = adapter.buildRequest({ ...params, provider, abortSignal: options.abortSignal || null });
          // Intentionally NOT storing url on the attempt record: Gemini embeds the API
          // key as a query param, and providerAttempts[] is echoed back through the
          // requestContext spread in proxy.request.finished. Keeping the URL out of
          // the persisted attempt keeps secrets out of logs unconditionally.
          fetchStartedAt = Date.now();
          logInfo("proxy.provider.fetch_start", {
            ...requestContext,
            providerId: entry.id,
            attempt: attempt.attempt,
            fetchStartedAt
          });
          response = await fetchImpl(url, init);
        } catch (error) {
          // 不变量违反(如 buildSystemPrompt 的 today 缺失)不属于 provider 故障,
          // 不应触发 failover 浪费其他 provider 配额。直接向上抛,由 handleRequest 的
          // catch 统一处理为 500。
          if (error instanceof ProxyHTTPError && error.body?.error === "invariant_violation") {
            throw error;
          }
          responseError = error;
        }

        // fetch_done 在 try/catch 外打:fetchStartedAt!==null 表示已进入 fetch 阶段
        // (buildRequest 已成功),此时无论 fetchImpl 成功/超时/网络错都打。失败时
        // providerStatus=null。本日志 + fetch_start 配对可精确算出上游 fetch 耗时,
        // 与 call_start/call_success 的总 durationMs 对比即可拆出 Worker 预处理/上游推理/后处理三段。
        if (fetchStartedAt !== null) {
          logInfo("proxy.provider.fetch_done", {
            ...requestContext,
            providerId: entry.id,
            attempt: attempt.attempt,
            fetchStartedAt,
            fetchMs: Date.now() - fetchStartedAt,
            providerStatus: response?.status ?? null
          });
        }

        attempt.durationMs = Date.now() - attempt.startedAt;

        if (responseError) {
          // 客户端断连:上游 fetch 是被 request.signal abort 掉的,不是 provider 故障。
          // 旧行为在这里做了两件错事 —— 给当前 provider 记一次 health failure,然后 failover
          // 到下一个 provider(它同样立刻被 abort,再记一次)。一次「用户划走弹层」= 两个
          // provider 各记一次假故障,threshold=5 时三次取消就能把两个 provider 全部熔断,
          // pickCandidates 返回空 → 503。这是「远端服务间歇性不生效」的服务端主因。
          //
          // 判据用 options.abortSignal.aborted 而不是 error.name === "AbortError":
          // mergeSignals 把客户端信号和 AbortSignal.timeout(timeoutMs) 合并后传给上游,
          // 两者冒出来的 error.name 在不同 runtime 下并不稳定(AbortError / TimeoutError),
          // 而 abortSignal.aborted 是对「客户端是否已经走了」的直接读数。
          if (options.abortSignal?.aborted) {
            logInfo("proxy.client.disconnected", {
              ...requestContext,
              providerId: entry.id,
              attempt: attempt.attempt,
              phase: "pre_response",
              elapsedMs: attempt.durationMs
            });
            // 499 = nginx 惯例「客户端主动断开」。没人在听这个响应,但它让
            // proxy.request.finished 记成 499 而不是 503,错误看板不再把用户取消算成故障。
            throw new ProxyHTTPError(499, "Client disconnected", { errorType: "client_disconnected" });
          }
          const errorType = classifyFetchError(responseError);
          const classification = adapter.isRetryable({ status: null, bodyText: "", errorType });
          attempt.errorType = classification.errorType;
          attempt.errorMessage = redactText(responseError?.message || String(responseError), providerRedactions(provider));
          attempts.push(attempt);
          recordAttempts(requestContext, attempts, entry.id);
          logProviderFailure(provider, attempt, classification, requestContext, responseError, undefined, hasNext);
          // 超时/网络错是条目级(同条目所有 key 共享后端线路)→ 记全部可用 key。
          if (classification.retryable && healthStore && classification.countsTowardCircuit !== false) {
            await recordFailureAllKeys(healthStore, usableKeys, classification.errorType);
          }
          if (classification.errorType === "auth") {
            attachAuthReason(attempt, classification, provider, requestContext);
          }
          if (!classification.retryable) {
            // Hard-fail on non-retryable error — aborting the failover chain is safer
            // than continuing when the caller's environment is broken.
            throw new ProxyHTTPError(502, `Provider ${entry.id} failed before response`);
          }
          advanceToNextEntry = true;
          break;
        }

        attempt.providerStatus = response.status;

        if (!response.ok) {
          let bodyText = "";
          let errorBodyTruncated = false;
          let errorBodyBytes = 0;
          try {
            const errorBody = await readResponseTextWithLimit(response, MAX_PROVIDER_ERROR_BODY_BYTES);
            bodyText = errorBody.text;
            errorBodyTruncated = errorBody.truncated;
            errorBodyBytes = errorBody.bytesRead;
          } catch (readError) {
            logWarn("proxy.provider.error_body_unreadable", {
              ...requestContext,
              providerId: entry.id,
              ...errorFields(readError, { redactions: providerRedactions(provider) })
            });
          }
          const classification = adapter.isRetryable({ status: response.status, bodyText });
          attempt.errorType = classification.errorType;
          if (errorBodyTruncated) {
            attempt.errorBodyTruncated = true;
            attempt.errorBodyBytes = errorBodyBytes;
          }
          attempts.push(attempt);
          recordAttempts(requestContext, attempts, entry.id);
          logProviderFailure(provider, attempt, classification, requestContext, null, response.status, hasNext);
          // countsTowardCircuit === false 表示「上游此刻忙」(429 并发/速率,z.ai 1302/1305):
          // failover 照走、attempt 照记(便于 D1 统计上游忙次数),但不计熔断。
          // 注意也不 recordSuccess —— 不计熔断 ≠ 记成功:瞬间返回的 429 记成功会让
          // selector 的延迟 EWMA 误判这家「极快」而压更多流量(任务书 §5 风险 1)。
          // 余额/额度耗尽的 429(z.ai 1113)在 base.js 被归为 quota_exhausted,
          // countsTowardCircuit 未设为 false → 照旧计熔断(不会自愈,熔断才不白打)。
          if (classification.retryable && healthStore && classification.countsTowardCircuit !== false) {
            if (isKeyScopedFailure(classification)) {
              // key 级(429 忙例外上面已挡,这里实际是 quota/auth):只记当前 key
              await healthStore.recordFailure(chosenKey.healthId, classification.errorType);
            } else {
              await recordFailureAllKeys(healthStore, usableKeys, classification.errorType);
            }
          }
          if (classification.errorType === "auth") {
            attachAuthReason(attempt, classification, provider, requestContext);
          }
          if (!classification.retryable) {
            // 4xx request-body problem: another provider would reject the same payload.
            throw new ProxyHTTPError(502, `Provider ${entry.id} rejected request (status ${response.status})`);
          }
          if (isKeyScopedFailure(classification) && untriedKeys.size > 0) {
            // R4:立即返回的 key 级失败 → 换同条目另一个 key,不消耗条目尝试数。
            // lease 在循环顶部的「换 key 前先还」处释放。
            continue;
          }
          advanceToNextEntry = true;
          break;
        }

        let bodyResult = null;
        if (onResponse) {
          try {
            bodyResult = await onResponse({ response, provider, adapter, attempt });
            attempt.durationMs = Date.now() - attempt.startedAt;
          } catch (validationError) {
            attempt.durationMs = Date.now() - attempt.startedAt;
            const classification = {
              retryable: true,
              errorType: validationError?.errorType || "invalid_response"
            };
            attempt.errorType = classification.errorType;
            attempt.errorMessage = redactText(validationError?.message || String(validationError), providerRedactions(provider));
            attempts.push(attempt);
            recordAttempts(requestContext, attempts, entry.id);
            logProviderFailure(provider, attempt, classification, requestContext, validationError, response.status, hasNext);
            if (healthStore) {
              // 响应无效是模型/条目级问题 → 记全部可用 key
              await recordFailureAllKeys(healthStore, usableKeys, classification.errorType);
            }
            if (!hasNext) {
              throw validationError instanceof ProxyHTTPError
                ? validationError
                : new ProxyHTTPError(502, "AI provider response invalid", { cause: validationError, errorType: classification.errorType });
            }
            advanceToNextEntry = true;
            break;
          }
        }

        attempts.push(attempt);
        recordAttempts(requestContext, attempts, entry.id);
        requestContext.providerUsed = entry.id;
        requestContext.failoverCount = index;

        logInfo("proxy.provider.call_success", {
          ...requestContext,
          providerId: entry.id,
          provider: entry.type,
          model: entry.model,
          attempt: attempt.attempt,
          providerStatus: response.status,
          durationMs: attempt.durationMs,
          stream
        });

        // Defer healthStore.recordSuccess to the caller: HTTP 200 only means the
        // connection succeeded, not that the body is valid. The caller invokes
        // confirmSuccess() after successfully extracting text from the response.
        const confirmSuccess = async () => {
          if (healthStore) {
            await healthStore.recordSuccess(chosenKey.healthId, attempt.durationMs);
          }
        };
        const confirmFailure = async (errorType = "stream") => {
          if (healthStore) {
            await healthStore.recordFailure(chosenKey.healthId, errorType);
          }
        };

        if (stream) {
          // 流式:响应体还没读,租约必须活到流结束 → 所有权移交调用方
          // (worker.js 把 release 挂进 normalizeProviderStream 的 onSettled)。
          transferredLease = lease;
          return { provider, adapter, response, attempts, bodyResult, lease: transferredLease, confirmSuccess, confirmFailure };
        }

        // 非流式:body 已在 onResponse 里读完 → 立即释放名额
        if (lease) {
          await lease.release();
          activeLease = null;
        }
        return { provider, adapter, response, attempts, bodyResult, lease: null, confirmSuccess, confirmFailure };
      }
    }
  } finally {
    // 租约兜底:所有未移交(throw/条目耗尽)路径在这里释放。幂等,重复 release 无害。
    if (activeLease && transferredLease !== activeLease) {
      await activeLease.release();
    }
  }

  logError("proxy.provider.all_failed", {
    ...requestContext,
    providersTried: attempts.map((a) => a.providerId),
    attempts
  });
  throw new ProxyHTTPError(503, "All providers unavailable");
}

function pickRandomKey(keys) {
  if (keys.length === 1) return keys[0];
  return keys[Math.floor(keyPickRandom() * keys.length)];
}

async function recordFailureAllKeys(healthStore, keys, errorType) {
  await Promise.all(keys.map((key) => healthStore.recordFailure(key.healthId, errorType)));
}

function attachAuthReason(attempt, classification, provider, requestContext) {
  // authReason 指向具体该做哪件事:换密钥 / 充值 / 换出口 / 开通模型权限。
  // 挂到 attempt 上是为了让它随 providerAttempts[] 一起被 proxy.request.finished
  // 回显,能按 requestId 把整条失败链串起来看。
  attempt.authReason = classification.authReason || "unknown";
  logWarn("proxy.provider.auth_failed_alert", {
    ...requestContext,
    providerId: provider.id,
    provider: provider.type,
    authReason: attempt.authReason
  });
}

function classifyFetchError(error) {
  if (error?.name === "AbortError") return "timeout";
  if (error?.name === "TimeoutError") return "timeout";
  if (error?.name === "TypeError") return "network";
  return "network";
}

async function readResponseTextWithLimit(response, maxBytes) {
  if (!response.body) {
    return { text: "", bytesRead: 0, truncated: false };
  }

  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let bytesRead = 0;
  let text = "";
  let truncated = false;

  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) {
        break;
      }

      if (bytesRead + value.byteLength > maxBytes) {
        const allowed = Math.max(0, maxBytes - bytesRead);
        if (allowed > 0) {
          text += decoder.decode(value.slice(0, allowed), { stream: true });
          bytesRead += allowed;
        }
        truncated = true;
        await reader.cancel("Provider error body too large");
        break;
      }

      bytesRead += value.byteLength;
      text += decoder.decode(value, { stream: true });
    }
    text += decoder.decode();
    return { text, bytesRead, truncated };
  } finally {
    reader.releaseLock();
  }
}

function recordAttempts(requestContext, attempts, lastProviderId) {
  requestContext.providerAttempts = attempts;
  requestContext.providersTried = attempts.map((a) => a.providerId);
  if (lastProviderId) {
    requestContext.lastProviderTried = lastProviderId;
  }
}

function logProviderFailure(provider, attempt, classification, requestContext, error, status, hasNext = true) {
  const fields = {
    ...requestContext,
    providerId: provider.id,
    provider: provider.type,
    model: provider.model,
    attempt: attempt.attempt,
    durationMs: attempt.durationMs,
    errorType: classification.errorType,
    retryable: classification.retryable
  };
  if (attempt.keySlot) {
    fields.keySlot = attempt.keySlot;
  }
  if (typeof status === "number") {
    fields.providerStatus = status;
  }
  if (attempt.errorBodyTruncated) {
    fields.errorBodyTruncated = true;
    fields.errorBodyBytes = attempt.errorBodyBytes;
  }
  if (error) {
    Object.assign(fields, errorFields(error, { redactions: providerRedactions(provider) }));
  }
  // Intentionally NOT logging provider error body: upstream 4xx/5xx responses can
  // echo back the user's transcript or other sensitive content. Status code +
  // errorType classification is sufficient for debugging without PII risk.
  logWarn("proxy.provider.call_failed", fields);
  if (classification.retryable && hasNext) {
    // Signal that the executor is moving on to the next candidate. The next
    // call_start log will name the actual next provider; this event lets
    // dashboards count failovers without parsing the attempt chain.
    logInfo("proxy.provider.failover", {
      ...requestContext,
      fromProviderId: provider.id,
      reason: classification.errorType
    });
  }
}

// 脱敏清单覆盖条目全部 key(任务书 §7:providerRedactions 要覆盖到多 key)。
// provider 是「条目 + 已选 key」的浅合并(caller 视角),keys[] 仍携带整池。
function providerRedactions(provider) {
  const keys = Array.isArray(provider.keys) && provider.keys.length > 0
    ? provider.keys.map((k) => k.apiKey || "")
    : [provider.apiKey || ""];
  return keys.flatMap((apiKey) => [apiKey, encodeURIComponent(apiKey)]).filter(Boolean);
}

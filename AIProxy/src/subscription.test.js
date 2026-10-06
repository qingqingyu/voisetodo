import assert from "node:assert/strict";
import test from "node:test";
import { verifySubscriptionJWS, base64urlDecode } from "./subscription.js";
import { parseCertificate } from "./asn1.js";
import { mintTestJWS, b64url } from "./jws-fixture.js";

const BUNDLE = "com.voicetodo.app";
const PRODUCTS = ["com.voicetodo.pro.monthly", "com.voicetodo.pro.yearly"];

function verify(jws, rootFp, opts = {}) {
  return verifySubscriptionJWS(jws, {
    expectedBundleId: BUNDLE,
    productIDs: PRODUCTS,
    rootFingerprint: rootFp,
    ...opts
  });
}

test("verifies a valid StoreKit-style JWS with anchored chain", async () => {
  const { jws, rootFingerprint } = await mintTestJWS({ productId: PRODUCTS[0] });
  const result = await verify(jws, rootFingerprint);
  assert.equal(result.productId, PRODUCTS[0]);
  assert.ok(result.expiresAt > Date.now());
  // 无订阅标识的 payload:subscriptionId 落 null(调用方显式跳过按订阅限速,不静默)
  assert.equal(result.subscriptionId, null);
});

// 订阅标识提取(按订阅限速的键):originalTransactionId 在一次购买内跨设备稳定,
// 优先于每次续订都变的 transactionId;数字形态归一为字符串;两者皆缺 → null。
test("extracts subscriptionId from payload (originalTransactionId preferred)", async () => {
  const { jws: jwsBoth, rootFingerprint } = await mintTestJWS({
    payload: { originalTransactionId: "tx-orig-001", transactionId: "tx-renew-009" }
  });
  const both = await verify(jwsBoth, rootFingerprint);
  assert.equal(both.subscriptionId, "tx-orig-001");

  const { jws: jwsRenewOnly, rootFingerprint: renewFp } = await mintTestJWS({ payload: { transactionId: "tx-renew-009" } });
  const renewOnly = await verify(jwsRenewOnly, renewFp);
  assert.equal(renewOnly.subscriptionId, "tx-renew-009");

  const { jws: jwsNumeric, rootFingerprint: numericFp } = await mintTestJWS({ payload: { originalTransactionId: 123456789 } });
  const numeric = await verify(jwsNumeric, numericFp);
  assert.equal(numeric.subscriptionId, "123456789");
});

test("rejects forged JWS signature", async () => {
  const { jws, rootFingerprint } = await mintTestJWS({});
  const parts = jws.split(".");
  const tampered = `${parts[0]}.${parts[1]}.${parts[2].slice(0, -4)}AAAA`;
  await assert.rejects(() => verify(tampered, rootFingerprint), /jws_signature_invalid/);
});

test("rejects expired subscription", async () => {
  const { jws, rootFingerprint } = await mintTestJWS({ payload: { expiresDateMS: Date.now() - 86400000 } });
  await assert.rejects(() => verify(jws, rootFingerprint), /expired/);
});

test("rejects revoked (refunded) subscription", async () => {
  const { jws, rootFingerprint } = await mintTestJWS({ payload: { revocationDate: Date.now() - 3600000, revocationReason: 0 } });
  await assert.rejects(() => verify(jws, rootFingerprint), /revoked/);
});

test("rejects subscription JWS without an expiry claim", async () => {
  const { jws, rootFingerprint } = await mintTestJWS({ payload: { expiresDateMS: null } });
  await assert.rejects(() => verify(jws, rootFingerprint), /expires_missing/);
});

test("rejects wrong root anchor", async () => {
  const { jws } = await mintTestJWS({});
  await assert.rejects(() => verify(jws, "deadbeef".repeat(8)), /root_anchor_mismatch/);
});

// 第三轮 review 新问题 3:根锚定必须先于链验签 —— 根指纹比对是一次 SHA-256,
// 链验签是 N-1 次公钥运算。伪造 JWS(链本身也必然验不过)要先被廉价闸门
// 拦下,不能强制烧完昂贵验签才拒绝。
test("checks root anchor before chain signatures (cheap gate first)", async () => {
  const { jws, rootFingerprint } = await mintTestJWS({});
  const [headerB64, payloadB64, signatureB64] = jws.split(".");
  const header = JSON.parse(new TextDecoder().decode(base64urlDecode(headerB64)));
  // 改坏链顶(root)证书字节:根指纹必然对不上,逐级验签也必然过不了。
  // 锚定先行时应直接报 root_anchor_mismatch;若实现退回「先验签后锚定」,
  // 损坏的 root 会先被当作签发者解析/验签,报出别的错 —— 测试即失败。
  const corrupted = base64urlDecode(header.x5c[header.x5c.length - 1]);
  corrupted[corrupted.length - 1] ^= 0xff;
  header.x5c[header.x5c.length - 1] = b64url(corrupted);
  const rebuiltHeader = b64url(new TextEncoder().encode(JSON.stringify(header)));
  await assert.rejects(
    () => verify(`${rebuiltHeader}.${payloadB64}.${signatureB64}`, rootFingerprint),
    /root_anchor_mismatch/
  );
});

test("rejects mismatched bundle id", async () => {
  const { jws, rootFingerprint } = await mintTestJWS({ bundleId: "com.evil.app" });
  await assert.rejects(() => verify(jws, rootFingerprint), /bundle_mismatch/);
});

test("rejects mismatched product id", async () => {
  const { jws, rootFingerprint } = await mintTestJWS({ productId: "com.other.product" });
  await assert.rejects(() => verify(jws, rootFingerprint), /product_mismatch/);
});

test("rejects malformed JWS", async () => {
  await assert.rejects(() => verifySubscriptionJWS("not-a-jws", {}), /jws_malformed/);
});

test("asn1 parser extracts leaf public key algorithm", async () => {
  const { jws } = await mintTestJWS({});
  const header = JSON.parse(new TextDecoder().decode(base64urlDecode(jws.split(".")[0])));
  const leaf = parseCertificate(base64urlDecode(header.x5c[0]));
  assert.equal(leaf.publicKey.algorithmOID, "1.2.840.10045.2.1"); // id-ecPublicKey
  assert.equal(leaf.publicKey.curveOID, "1.2.840.10045.3.1.7");   // P-256
});

import assert from "node:assert/strict";
import test from "node:test";
import { verifySubscriptionJWS, base64urlDecode } from "./subscription.js";
import { parseCertificate } from "./asn1.js";
import { mintTestJWS } from "./jws-fixture.js";

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

test("rejects subscription JWS without an expiry claim", async () => {
  const { jws, rootFingerprint } = await mintTestJWS({ payload: { expiresDateMS: null } });
  await assert.rejects(() => verify(jws, rootFingerprint), /expires_missing/);
});

test("rejects wrong root anchor", async () => {
  const { jws } = await mintTestJWS({});
  await assert.rejects(() => verify(jws, "deadbeef".repeat(8)), /root_anchor_mismatch/);
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

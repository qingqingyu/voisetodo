// StoreKit 2 订阅 JWS 验签（零依赖、零信任）。
//
// 验签流程：
//   1. 解析 compact JWS（header.payload.signature）。
//   2. 从 header.x5c 取证书链 [leaf, intermediate, root]。
//   3. 校验链：cert[i] 由 cert[i+1] 签发，链顶 root 的 SHA-256 等于锚定值（Apple Root CA - G3）。
//   4. 用 leaf 公钥校验 JWS 签名（ES256 = ECDSA P-256 SHA-256）。
//   5. 校验 payload：bundleId、productId、expiresDate（未过期）。
//
// 任一步失败 → 抛错（调用方 fail-safe 到免费档，不静默吞掉）。
//
// 不引第三方库：用 WebCrypto + 自带 ASN.1 解析（./asn1.js）。

import {
  parseCertificate,
  algorithmForSigOID,
  decodeOID,
  children,
  readTLV,
  OID_EC_PUBLIC_KEY,
  OID_RSA_ENCRYPTION,
  OID_P256,
  OID_P384
} from "./asn1.js";

// 锚定根证书 SHA-256（DER 全文指纹）。Apple Root CA - G3。
// 生产环境信任锚：链顶证书必须等于此值，否则视为不可信。
export const APPLE_ROOT_CA_G3_SHA256 = "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179";

/// base64url → Uint8Array（容忍省略 padding）。
export function base64urlDecode(str) {
  const pad = str.length % 4 === 0 ? "" : "=".repeat(4 - (str.length % 4));
  const b64 = (str + pad).replace(/-/g, "+").replace(/_/g, "/");
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/// Uint8Array → hex。
function toHex(buf) {
  return Array.from(buf).map((b) => b.toString(16).padStart(2, "0")).join("");
}

/// SHA-256(der) hex。
async function sha256Hex(buf) {
  const digest = await globalThis.crypto.subtle.digest("SHA-256", buf);
  return toHex(new Uint8Array(digest));
}

/// 校验证书链：certs[i] 由 certs[i+1] 签发，链顶等于锚定根。
async function verifyChain(certs, rootFingerprint) {
  if (certs.length < 2) throw new Error("subscription.chain_too_short");
  // 自顶向下：root → intermediate → leaf
  for (let i = certs.length - 1; i > 0; i--) {
    const subject = parseCertificate(certs[i - 1]); // 被签者
    const issuer = parseCertificate(certs[i]);       // 签发者
    const alg = algorithmForSigOID(subject.signatureAlgorithmOID);
    if (!alg) throw new Error(`subscription.unsupported_sig_alg ${subject.signatureAlgorithmOID}`);
    const issuerKey = await importPublicKey(issuer.publicKey, alg);
    const ok = await globalThis.crypto.subtle.verify(alg, issuerKey, subject.signatureBytes, subject.tbsBytes);
    if (!ok) throw new Error(`subscription.chain_signature_invalid level=${i - 1}`);
  }
  // 锚定根：链顶证书的 SHA-256 必须等于信任锚。
  const rootParsed = parseCertificate(certs[certs.length - 1]);
  void rootParsed;
  const rootFp = await sha256Hex(certs[certs.length - 1]);
  if (rootFp !== rootFingerprint) {
    throw new Error(`subscription.root_anchor_mismatch expected=${rootFingerprint} actual=${rootFp}`);
  }
}

/// 用 SPKI 导入公钥（ECDSA / RSA），用于 verify。
async function importPublicKey(spki, alg) {
  if (spki.algorithmOID === OID_EC_PUBLIC_KEY) {
    let namedCurve;
    if (spki.curveOID === OID_P256) namedCurve = "P-256";
    else if (spki.curveOID === OID_P384) namedCurve = "P-384";
    else throw new Error(`subscription.unknown_ec_curve ${spki.curveOID}`);
    return globalThis.crypto.subtle.importKey(
      "spki",
      spki.rawSPKI,
      { name: alg.name, namedCurve, hash: alg.hash },
      false,
      ["verify"]
    );
  }
  if (spki.algorithmOID === OID_RSA_ENCRYPTION || spki.algorithmOID === "1.2.840.113549.1.1.1") {
    return globalThis.crypto.subtle.importKey(
      "spki",
      spki.rawSPKI,
      { name: "RSASSA-PKCS1-v1_5", hash: alg.hash },
      false,
      ["verify"]
    );
  }
  throw new Error(`subscription.unknown_key_alg ${spki.algorithmOID}`);
}

/// ECDSA 签名从 raw r||s 转为 DER（JWS 用 raw 格式，WebCrypto 需 DER）。
function ecdsaRawToDer(raw) {
  const half = raw.length / 2;
  const r = normalizeInteger(raw.subarray(0, half));
  const s = normalizeInteger(raw.subarray(half));
  const body = new Uint8Array(2 + r.length + 2 + s.length);
  let off = 0;
  body[off++] = 0x02; // INTEGER
  body[off++] = r.length;
  body.set(r, off); off += r.length;
  body[off++] = 0x02; // INTEGER
  body[off++] = s.length;
  body.set(s, off);
  // SEQUENCE wrapper
  const out = new Uint8Array(2 + body.length);
  out[0] = 0x30;
  out[1] = body.length;
  out.set(body, 2);
  return out;
}

/// 整数前导零处理：去掉多余前导零，但保留符号位所需的零。
function normalizeInteger(bytes) {
  let start = 0;
  while (start < bytes.length - 1 && bytes[start] === 0x00 && (bytes[start + 1] & 0x80) === 0) {
    start++;
  }
  // 若最高位为 1，需补一个 0 前缀以表示正数。
  if ((bytes[start] & 0x80) !== 0) {
    const padded = new Uint8Array(bytes.length - start + 1);
    padded[0] = 0x00;
    padded.set(bytes.subarray(start), 1);
    return padded;
  }
  return bytes.subarray(start);
}

/**
 * 验证 StoreKit 2 订阅 JWS。
 * @param {string} jws compact JWS
 * @param {object} opts { expectedBundleId, productIDs, rootFingerprint?, now? }
 * @returns {Promise<{productId: string, expiresAt: number}>} 校验通过返回关键声明
 * @throws 校验任一步失败即抛错（调用方 fail-safe 到免费档）
 */
export async function verifySubscriptionJWS(jws, opts = {}) {
  const rootFingerprint = opts.rootFingerprint || APPLE_ROOT_CA_G3_SHA256;
  const now = typeof opts.now === "number" ? opts.now : Date.now();
  const expectedBundleId = opts.expectedBundleId;
  const productIDs = opts.productIDs || [];

  const parts = String(jws).split(".");
  if (parts.length !== 3) throw new Error("subscription.jws_malformed");
  const [headerB64, payloadB64, signatureB64] = parts;
  const headerBytes = base64urlDecode(headerB64);
  const payloadBytes = base64urlDecode(payloadB64);
  const signatureRaw = base64urlDecode(signatureB64);

  const header = JSON.parse(new TextDecoder().decode(headerBytes));
  if (header.alg !== "ES256") throw new Error(`subscription.unexpected_alg ${header.alg}`);
  if (!Array.isArray(header.x5c) || header.x5c.length < 2) throw new Error("subscription.x5c_missing");

  const certs = header.x5c.map((b64) => base64urlDecode(b64));

  // 1. 证书链锚定 Apple Root CA
  await verifyChain(certs, rootFingerprint);

  // 2. JWS 签名（ES256 = ECDSA P-256 SHA-256）。签名输入 = ASCII(headerB64 || "." || payloadB64)。
  const leaf = parseCertificate(certs[0]);
  const signingInput = new TextEncoder().encode(`${headerB64}.${payloadB64}`);
  const leafKey = await importPublicKey(leaf.publicKey, { name: "ECDSA", hash: "SHA-256" });
  // WebCrypto 规范要求 ECDSA 签名为 DER（Workers / 浏览器）；Node 实现期望 raw r||s。
  // compact JWS 永远存 raw r||s，故先转 DER 验（生产 Workers 走此分支）；
  // 再退回 raw 验（Node 测试环境走此分支）。两种形式编码同一 (r,s)，等价。
  const sigDer = ecdsaRawToDer(signatureRaw);
  let sigOk = await globalThis.crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    leafKey,
    sigDer,
    signingInput
  );
  if (!sigOk) {
    sigOk = await globalThis.crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      leafKey,
      signatureRaw,
      signingInput
    );
  }
  if (!sigOk) throw new Error("subscription.jws_signature_invalid");

  // 3. payload 声明
  const payload = JSON.parse(new TextDecoder().decode(payloadBytes));
  const bundleId = payload.bundleId || payload.bundleIdentifier;
  if (expectedBundleId && bundleId !== expectedBundleId) {
    throw new Error(`subscription.bundle_mismatch expected=${expectedBundleId} actual=${bundleId}`);
  }
  const productId = payload.productId || payload.productIdentifier;
  if (productIDs.length > 0 && !productIDs.includes(productId)) {
    throw new Error(`subscription.product_mismatch ${productId}`);
  }
  // expiresDate：StoreKit 用 ms（expiresDateMS）或秒（expiresDate）
  const expiresAt = normalizeExpiry(payload);
  if (!(typeof expiresAt === "number" && Number.isFinite(expiresAt))) {
    throw new Error("subscription.expires_missing");
  }
  if (expiresAt <= now) {
    throw new Error(`subscription.expired expiresAt=${expiresAt} now=${now}`);
  }
  return { productId, expiresAt };
}

function normalizeExpiry(payload) {
  for (const key of ["expiresDateMS", "expiresDateMs", "originalExpiresDateMS"]) {
    if (typeof payload[key] === "number" && payload[key] > 0) return payload[key];
  }
  if (typeof payload.expiresDate === "number" && payload.expiresDate > 0) {
    // seconds → ms（App Store Server API 的 expiresDate 是 ms；StoreKit Transaction 的 expiresDate 是秒）
    return payload.expiresDate > 1e12 ? payload.expiresDate : payload.expiresDate * 1000;
  }
  return null;
}

export { decodeOID, children, readTLV };

// Test-only fixture: mint StoreKit-style ES256 JWS with a synthetic CA chain.
// Used by subscription.test.js (verifier unit tests) and worker.test.js (tier routing).
// NOT shipped to production — only imported by tests.
import { webcrypto } from "node:crypto";
import { readTLV, children } from "./asn1.js";

const subtle = webcrypto.subtle;

const OID_EC = "1.2.840.10045.2.1";
const OID_ECDSA_SHA384 = "1.2.840.10045.4.3.3";
const OID_CN = "2.5.4.3";

function encLen(n) {
  if (n < 0x80) return Buffer.from([n]);
  const bytes = [];
  let v = n;
  while (v > 0) { bytes.unshift(v & 0xff); v = Math.floor(v / 256); }
  return Buffer.from([0x80 | bytes.length, ...bytes]);
}
function encTLV(tag, content) { return Buffer.concat([Buffer.from([tag]), encLen(content.length), content]); }
function encInt(n) {
  if (n === 0) return encTLV(0x02, Buffer.from([0]));
  const bytes = []; let v = n;
  while (v > 0) { bytes.unshift(v & 0xff); v = Math.floor(v / 256); }
  if (bytes[0] & 0x80) bytes.unshift(0);
  return encTLV(0x02, Buffer.from(bytes));
}
function encSeq(...parts) { return encTLV(0x30, Buffer.concat(parts)); }
function encSet(...parts) { return encTLV(0x31, Buffer.concat(parts)); }
function encOID(oid) {
  const parts = oid.split(".").map(Number);
  const out = [40 * parts[0] + parts[1]];
  for (let i = 2; i < parts.length; i++) {
    let v = parts[i]; const stack = [v & 0x7f]; v >>>= 7;
    while (v > 0) { stack.unshift(0x80 | (v & 0x7f)); v >>>= 7; }
    out.push(...stack);
  }
  return encTLV(0x06, Buffer.from(out));
}
function encBitString(bytes) { return encTLV(0x03, Buffer.concat([Buffer.from([0]), bytes])); }
function encUTF8(s) { return encTLV(0x0c, Buffer.from(s, "utf8")); }
function encUTCTime(d) {
  const p = (n) => String(n).padStart(2, "0");
  const s = `${p(d.getUTCFullYear() % 100)}${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}${p(d.getUTCHours())}${p(d.getUTCMinutes())}${p(d.getUTCSeconds())}Z`;
  return encTLV(0x17, Buffer.from(s, "ascii"));
}
function name(cn) { return encSeq(encSet(encSeq(encOID(OID_CN), encUTF8(cn)))); }

async function mintCert(subjectKey, issuerKey, { commonName, serial }) {
  const spki = new Uint8Array(await subtle.exportKey("spki", subjectKey.publicKey));
  const sigAlgId = encSeq(encOID(OID_ECDSA_SHA384));
  const tbs = encSeq(
    encTLV(0xA0, encSeq(encInt(2))),
    encInt(serial),
    sigAlgId,
    name(commonName + "-issuer"),
    encSeq(encUTCTime(new Date(Date.now() - 86400000)), encUTCTime(new Date(Date.now() + 86400000 * 365))),
    name(commonName),
    Buffer.from(spki)
  );
  const sigDer = new Uint8Array(await subtle.sign({ name: "ECDSA", hash: "SHA-384" }, issuerKey.privateKey, tbs));
  return Buffer.from(encSeq(tbs, sigAlgId, encBitString(Buffer.from(sigDer))));
}

export function b64url(buf) {
  return Buffer.from(buf).toString("base64").replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
}

function stripAndPad(intBytes, len) {
  let start = 0;
  while (start < intBytes.length && intBytes[start] === 0) start++;
  const trimmed = intBytes.subarray(start);
  if (trimmed.length > len) throw new Error(`ecdsa int too long ${trimmed.length} > ${len}`);
  const out = new Uint8Array(len);
  out.set(trimmed, len - trimmed.length);
  return out;
}

/// 归一 subtle.sign 输出为 raw r||s（Node 返回 raw，规范返回 DER）。
function signatureToRaw(sigBytes, halfLen) {
  const buf = sigBytes instanceof Uint8Array ? sigBytes : new Uint8Array(sigBytes);
  if (buf.length === halfLen * 2) return buf;
  const seq = readTLV(buf, 0);
  const kids = children(buf, seq);
  const r = stripAndPad(kids[0].view, halfLen);
  const s = stripAndPad(kids[1].view, halfLen);
  const out = new Uint8Array(halfLen * 2);
  out.set(r, 0);
  out.set(s, halfLen);
  return out;
}

/// 铸造合成 JWS：root P-384 自签 + leaf P-256 由 root 签。
/// 返回 { jws, rootFingerprint }。调用方把 rootFingerprint 作为信任锚传入验证。
export async function mintTestJWS({ payload, bundleId = "com.voicetodo.app", productId = "com.voicetodo.pro.yearly" }) {
  const rootKey = await subtle.generateKey({ name: "ECDSA", namedCurve: "P-384" }, true, ["sign", "verify"]);
  const leafKey = await subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const rootCert = await mintCert(rootKey, rootKey, { commonName: "Test Root", serial: 1 });
  const leafCert = await mintCert(leafKey, rootKey, { commonName: "Test Leaf", serial: 2 });
  const rootFingerprint = Buffer.from(await webcrypto.subtle.digest("SHA-256", rootCert)).toString("hex");

  const fullPayload = { bundleId, productId, expiresDateMS: Date.now() + 30 * 86400000, ...payload };
  const header = { alg: "ES256", x5c: [b64url(leafCert), b64url(rootCert)] };
  const headerB64 = b64url(new TextEncoder().encode(JSON.stringify(header)));
  const payloadB64 = b64url(new TextEncoder().encode(JSON.stringify(fullPayload)));
  const signingInput = new TextEncoder().encode(`${headerB64}.${payloadB64}`);
  const sig = new Uint8Array(await subtle.sign({ name: "ECDSA", hash: "SHA-256" }, leafKey.privateKey, signingInput));
  const sigRaw = signatureToRaw(sig, 32);
  return { jws: `${headerB64}.${payloadB64}.${b64url(sigRaw)}`, rootFingerprint };
}

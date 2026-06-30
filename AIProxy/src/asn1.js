// Minimal DER/ASN.1 parser sufficient to verify X.509 certificate chains and
// JWS (ES256) signatures, with zero runtime dependencies.
//
// Scope: walk TLV (tag-length-value) structures; extract the pieces needed for
// signature verification from a Certificate (TBSCertificate, signatureAlgorithm
// OID, signatureValue BIT STRING, SubjectPublicKeyInfo). Not a general-purpose
// ASN.1 library — it intentionally covers only the shapes Apple's JWS x5c uses.

// Tag constants
const TAG_INTEGER = 0x02;
const TAG_BIT_STRING = 0x03;
const TAG_OID = 0x06;
const TAG_SEQUENCE = 0x30;
const TAG_CTX0 = 0xA0; // [0] context-specific (version in TBSCertificate)

/// Read a single TLV node starting at `offset`.
/// Returns { tag, headerLen, contentStart, contentEnd, next, full }.
export function readTLV(buf, offset) {
  if (offset + 2 > buf.length) {
    throw new Error("asn1.truncated_header");
  }
  const tag = buf[offset];
  let lenByte = buf[offset + 1];
  let headerLen = 2;
  let length;
  if ((lenByte & 0x80) === 0) {
    length = lenByte;
  } else {
    const numBytes = lenByte & 0x7f;
    headerLen = 2 + numBytes;
    if (offset + headerLen > buf.length) {
      throw new Error("asn1.truncated_length");
    }
    length = 0;
    for (let i = 0; i < numBytes; i++) {
      length = (length << 8) | buf[offset + 2 + i];
    }
  }
  const contentStart = offset + headerLen;
  const contentEnd = contentStart + length;
  if (contentEnd > buf.length) {
    throw new Error("asn1.truncated_content");
  }
  return { tag, headerLen, contentStart, contentEnd, next: contentEnd };
}

/// Parse a node into a structured form with its children (if SEQUENCE/SET).
export function parseNode(buf, offset) {
  const node = readTLV(buf, offset);
  const view = buf.subarray(node.contentStart, node.contentEnd);
  return { ...node, view };
}

/// Collect the immediate children of a constructed node (SEQUENCE/SET/context).
export function children(buf, node) {
  const out = [];
  let off = node.contentStart;
  while (off < node.contentEnd) {
    const child = readTLV(buf, off);
    out.push({ ...child, view: buf.subarray(child.contentStart, child.contentEnd) });
    off = child.next;
  }
  return out;
}

/// Decode an OID node into its dotted string.
export function decodeOID(node) {
  if (node.tag !== TAG_OID) throw new Error("asn1.not_an_oid");
  const bytes = node.view;
  if (bytes.length === 0) return "";
  const parts = [];
  let first = bytes[0];
  parts.push(String(Math.floor(first / 40)));
  parts.push(String(first % 40));
  let value = 0;
  for (let i = 1; i < bytes.length; i++) {
    value = (value << 7) | (bytes[i] & 0x7f);
    if ((bytes[i] & 0x80) === 0) {
      parts.push(String(value));
      value = 0;
    }
  }
  return parts.join(".");
}

/// Parse a full X.509 Certificate into the parts needed for chain verification.
/// Returns { tbsBytes, signatureAlgorithmOID, signatureBytes, publicKey: { algorithmOID, curveOID?, keyBytes, rawSPKI } }.
export function parseCertificate(der) {
  const buf = der instanceof Uint8Array ? der : new Uint8Array(der);
  const cert = readTLV(buf, 0);
  if (buf[0] !== TAG_SEQUENCE) throw new Error("asn1.cert_not_sequence");
  const certChildren = children(buf, cert);
  if (certChildren.length < 3) throw new Error("asn1.cert_too_short");
  const [tbsNode, sigAlgNode, sigValueNode] = certChildren;

  // signed bytes = the full TBSCertificate TLV (tag+length+content). tbsNode is the
  // first child of the Certificate SEQUENCE, so its tag starts at cert.contentStart.
  const tbsFull = buf.subarray(cert.contentStart, tbsNode.next);

  // signatureAlgorithm: AlgorithmIdentifier SEQUENCE → first child OID
  const sigAlgChildren = children(buf, sigAlgNode);
  if (sigAlgChildren.length < 1 || sigAlgChildren[0].tag !== TAG_OID) {
    throw new Error("asn1.sig_alg_missing_oid");
  }
  const signatureAlgorithmOID = decodeOID(sigAlgChildren[0]);

  // signatureValue: BIT STRING → skip the leading "unused bits" byte
  if (sigValueNode.tag !== TAG_BIT_STRING) throw new Error("asn1.sig_not_bitstring");
  const signatureBytes = buf.subarray(sigValueNode.contentStart + 1, sigValueNode.contentEnd);

  // Parse TBSCertificate to reach SubjectPublicKeyInfo.
  const tbsChildren = children(buf, tbsNode);
  let idx = 0;
  if (tbsChildren[0] && tbsChildren[0].tag === TAG_CTX0) {
    idx = 1; // skip optional version [0]
  }
  // children: [serial, sigAlg, issuer, validity, subject, spki, ...]
  const spkiNode = tbsChildren[idx + 5];
  if (!spkiNode || spkiNode.tag !== TAG_SEQUENCE) throw new Error("asn1.spki_missing");
  // Full SPKI TLV bytes (tag+length+content) for crypto.subtle.importKey with format "spki".
  const rawSPKI = buf.subarray(spkiNode.contentStart - spkiNode.headerLen, spkiNode.next);

  const spkiChildren = children(buf, spkiNode);
  const algIdNode = spkiChildren[0];
  const algChildren = children(buf, algIdNode);
  if (algChildren[0].tag !== TAG_OID) throw new Error("asn1.spki_alg_missing_oid");
  const algorithmOID = decodeOID(algChildren[0]);
  let curveOID = null;
  // For id-ecPublicKey the parameters contain the named curve OID.
  if (algChildren[1] && algChildren[1].tag === TAG_OID) {
    curveOID = decodeOID(algChildren[1]);
  }
  const keyBitString = spkiChildren[1];
  if (!keyBitString || keyBitString.tag !== TAG_BIT_STRING) throw new Error("asn1.spki_key_missing");
  const keyBytes = buf.subarray(keyBitString.contentStart + 1, keyBitString.contentEnd);

  return {
    tbsBytes: tbsFull,
    signatureAlgorithmOID,
    signatureBytes,
    publicKey: { algorithmOID, curveOID, keyBytes, rawSPKI }
  };
}

// Signature algorithm OIDs → { webcrypto name, hash }
export function algorithmForSigOID(oid) {
  switch (oid) {
    case "1.2.840.10045.4.3.2": return { name: "ECDSA", hash: "SHA-256" }; // ecdsa-with-SHA256
    case "1.2.840.10045.4.3.3": return { name: "ECDSA", hash: "SHA-384" }; // ecdsa-with-SHA384
    case "1.2.840.113549.1.1.11": return { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" };
    case "1.2.840.113549.1.1.12": return { name: "RSASSA-PKCS1-v1_5", hash: "SHA-384" };
    case "1.2.840.113549.1.1.13": return { name: "RSASSA-PKCS1-v1_5", hash: "SHA-512" };
    default: return null;
  }
}

// Public-key algorithm OIDs
export const OID_EC_PUBLIC_KEY = "1.2.840.10045.2.1";
export const OID_RSA_ENCRYPTION = "1.2.840.113549.1.1.1";
export const OID_P256 = "1.2.840.10045.3.1.7";
export const OID_P384 = "1.3.132.0.34";

export const TAG_INTEGER_CONST = TAG_INTEGER;

<!--
  Publication source for https://qingqingyu.github.io/voicetodo-privacy/ (deployed 2026-08-16, GitHub Pages)
  Placeholders in [BRACKETS] resolved 2026-08-22 against the live page — see APPSTORE_REVIEW_KIT.md §0.
  ⚠️ 线上页尚无 Effective date 行,源文件已填 2026-08-16;下次更新线上页时同步补上。
  Every factual claim below was verified against the code as of 2026-08-15:
  - audio: Apple Speech framework, no on-device-only flag (Voice/VoiceInputManager.swift)
  - transcript: sent to AIProxy (Cloudflare Worker), forwarded to Anthropic/OpenAI/Google
  - result cache: KV, TTL 1h, key = one-way hash (AIProxy/src/extractionCache.js)
  - todos/calendar: local only (SwiftData, EventKit)
  - subscription: StoreKit 2 JWS verified server-side, {tier, productId, expiresAt} cached in KV
  - telemetry: hashed device ID + event data, D1, 90-day GC (TELEMETRY.md)
  - feedback: feedback-relay worker → internal notification + D1 archive
  If any of the above changes, update this page in the same release.
-->

# Privacy Policy

**Effective date:** 2026-08-16

This policy explains what data VoiceTodo ("the app") handles, where it goes, and how long it is kept. It applies to the VoiceTodo iOS app operated by an independent developer ("we", "us").

**Contact:** 334678754@qq.com

## Summary

- You do not need an account. We do not know who you are.
- Your to-do list and calendar data stay on your device.
- We never store your audio.
- To turn a spoken sentence into structured to-dos, the transcript **text** is sent to our server and to an AI provider. It is processed in real time and not archived.
- We do not track you, we do not show ads, we do not sell or share your data, and we do not use your content to train models.
- Payments are processed entirely by Apple. We never see your name, Apple ID, or payment details.

## What VoiceTodo does

VoiceTodo converts spoken input into structured to-dos (dates, recurrence, categories, reminders). Speech recognition is performed by Apple's Speech framework; turning the resulting text into structured to-dos is done by an AI model through our server. Everything else — your to-do list, widgets, calendar integration — runs locally on your device.

## Data we handle

### Speech and audio

Voice capture and speech recognition are handled by Apple's Speech framework. Depending on your device, language, and network conditions, Apple may process audio on your device or on Apple's servers, under [Apple's privacy policies](https://www.apple.com/legal/privacy/). **We never receive, transmit to third parties, or store your audio.**

### Transcript text

After speech recognition, the transcript (text) is sent over an encrypted connection to our server — hosted on Cloudflare — which forwards it to an AI provider (such as Anthropic, OpenAI, or Google, depending on availability) to structure it into to-dos.

- The transcript is processed in real time. We do not log or archive it.
- Under the commercial API terms of the AI providers we use, content submitted via their APIs is not used to train their models.
- To avoid redundant AI calls when the same sentence is processed twice (for example, a retry after a network failure), the **structured result** may be cached on our server for up to **1 hour**. The cache is stored under a one-way hash of the request and is not linked to your identity.

### Your to-dos and calendar

Your to-do content is stored locally on your device (SwiftData, shared with the widget through the iOS App Group). It is never uploaded to our servers. Calendar access, if you enable it, is performed locally through Apple's EventKit. Deleting the app deletes your to-dos.

### Anonymous diagnostics

The app sends anonymous diagnostic events (for example: recording started, extraction succeeded or failed, duration, counts) so we can detect failures and improve reliability. These events include:

- a device identifier that is **one-way hashed** (SHA-256) before leaving your device — it cannot be reversed to identify you
- app version, iOS version, and coarse outcome codes
- counters and durations only — never the content of your recordings or to-dos

Diagnostics are kept for **90 days**, then automatically deleted. You can turn diagnostic reporting off at any time in the app's settings.

### Feedback

If you use the in-app feedback form, the text you write (and any diagnostic details attached to the message) is sent to us and archived so we can respond and fix issues. You can ask us to delete your feedback at any time via 334678754@qq.com.

### Purchases and device identifier

Payments and subscriptions are handled entirely by Apple; we never receive your name, Apple ID, or payment information.

To apply your Pro benefits (for example, a higher daily AI allowance), the app sends Apple's cryptographically signed transaction to our server for verification. Our server stores only:

- whether a Pro subscription is active, the product ID (monthly / yearly), and its expiry date
- associated with the same hashed device identifier described above

A hashed device identifier is also used to enforce the daily free-tier limit and to protect the service from abuse. It is a random/hashed value — not your Apple ID, advertising ID, or any permanent hardware serial.

## What we never do

- No accounts, no sign-in
- No tracking or profiling across apps or websites
- No advertising, no analytics SDKs from third parties
- No selling or sharing of your data
- No use of your transcripts or to-dos to train AI models
- No storage of audio

## Retention summary

| Data | Where | Kept for |
|------|-------|----------|
| Audio | Apple Speech framework only | Never stored by us |
| Transcript text | Our server / AI provider | Processed in real time, not archived |
| Structured result cache | Our server (Cloudflare KV) | ≤ 1 hour |
| Diagnostics (anonymous) | Our server (database) | 90 days |
| Feedback (if you send it) | Our server | Until you ask us to delete it |
| Subscription status + hashed device ID | Our server (cache) | Duration of the subscription |
| To-dos, settings, calendar data | Your device only | Until you delete the app |

## Third parties

- **Apple** — speech recognition, App Store distribution, in-app purchase processing
- **Cloudflare** — hosts our server infrastructure
- **AI providers — such as Anthropic, OpenAI, or Google** — receive the transcript text to structure it into to-dos

Each processes data under its own privacy policy. We only send them what is needed to perform the function described above.

## Your choices and rights

- **Delete local data:** delete the app — your to-dos and settings are removed with it.
- **Turn off diagnostics:** in the app's settings at any time.
- **Access or delete server-side data** (feedback, diagnostics, cached subscription status): email 334678754@qq.com. Because we only hold hashed identifiers, we may ask for the approximate date and content of your request to locate it.
- If you are in the EEA, UK, or another jurisdiction with similar law, you may also have rights to access, rectify, or erase personal data, and to lodge a complaint with a supervisory authority. We handle requests via the same email address.

We do not direct the app to children under 13, and do not knowingly collect personal data from children.

## International users

Our infrastructure (Cloudflare) and the AI providers may process data in the United States or other countries. Applicable safeguards (such as EU Standard Contractual Clauses where relevant) are in place with these providers.

## Changes to this policy

If we change how the app handles data, we will update this page and the effective date before the change ships in an app update. Continued use after an update means you accept the revised policy.

## Contact

Questions or requests: **334678754@qq.com**

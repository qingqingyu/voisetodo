# App Store 提审材料包(REVIEW KIT)

> 配套 `PROMOTION_PLAN.md`(策略)与 `PRIVACY_POLICY.md` / `TERMS_OF_USE.md`(发布源文件)。
> 定稿: 2026-08-15 · 状态: 待执行(占位符未解析、政策页未部署)
> 性质: **内档**,不对外。所有对外文案以两个英文源文件为准。

---

## 0. 占位符清单(部署前必须全部解析)

两份英文政策里有 `[BRACKET]` 占位符,各自的状态与动作:

| 占位符 | 出现于 | 当前状态 | 动作 |
|--------|--------|----------|------|
| `[DOMAIN]` | 政策页 URL、Terms 内链 | 未定 | 买域名(§5.1),候选: `voicetodo.app` / `getvoicetodo.com` / `voicetodoapp.com`,买前查可用性与商标 |
| `[SUPPORT_EMAIL]` | 两份政策 + ASC + 差评回复模板 | 未定 | 创建 iCloud 专用别名(如 `voicetodo@icloud.com`),设置 → Apple ID → 登录与安全 → App 专用/别名邮件;**确认能收信再发布** |
| `[DEVELOPER_NAME]` | 两份政策署名 | 未定 | 必须与 App Store Connect 开发者名称一致(个人开发者 = 账号法定名) |
| `[EFFECTIVE_DATE]` | 两份政策 | 未定 | 填政策页实际上线日(= 提交审核前) |
| `[TRIAL_DAYS]` | ~~Terms §3~~ | **已拍板: 7 天**(2026-08-15,按 PLAN 决策 7;Terms 已解析,Products.storekit 与文案已同步,ASC 配置见 §3.3) | ~~见 §3.3~~ 已办 |
| `[FREE_TIER_PER_DAY]` | Terms §3 | 依赖工程项 | = 上线时 `DAILY_REQUEST_LIMIT`(PLAN 已定 3,若仍是 2 则全局替换,含 PROMOTION_COPY) |
| `[JURISDICTION]` | Terms §9 | 未定 | 管辖法律,个人开发者通常写自己常住地;拿不准就写开发者所在地,别留空 |

---

## 1. Review Notes(英文,直接粘贴进 ASC「App 审核信息 → 备注」)

```
VoiceTodo turns one spoken sentence into structured to-dos (dates, recurrence,
categories) using AI. Here's how to test it:

NO ACCOUNT NEEDED. Free tier allows 3 AI extractions per day.

HOW TO TEST WITHOUT VOICE: on the main screen, tap the text input field at the
bottom of the screen and TYPE a sentence, for example:

  "team meeting tomorrow 10am, quarterly report by Friday, water the plants
   every Monday"

then press send. This runs the exact same AI extraction pipeline as voice
input. A confirmation sheet appears listing the parsed to-dos with dates,
times, recurrence and categories — review and tap confirm to save them.
(Voice recognition can be unreliable in Simulator; the typed path exercises
the identical processing.)

PERMISSIONS:
- Microphone + Speech Recognition: requested for voice capture, the core
  feature. Please grant when prompted.
- Calendar: NOT requested on launch. Only asked if the user enables
  "write to Apple Calendar" in settings. Safe to decline for review.

SUBSCRIPTION: VoiceTodo Pro is an auto-renewable subscription ($4.99/month
or $39.99/year, 7-day free trial) that raises the daily AI extraction
allowance. There are no other unlocks or digital goods. The free tier is
fully functional for review purposes.

PRIVACY: transcripts (text, not audio) are sent to our server and an AI
provider to structure them; audio is never stored. Full policy:
https://[DOMAIN]/privacy
```

替换 `3`(免费额度)为提审当日真实值,与 §6 自检一致;trial 天数已定 7(§3.3),无需当日再替换。

**审核注意点(预判):**
- 语音类 app 审核员第一反应是「模拟器没法测语音」——备注里的 typed path 就是为这个准备的,别删。
- 若被问 IAP 权益与额度:paywall 文案、Description、Review Notes 三处的额度说法必须一致(见 §6)。
- 首次提审建议在 ASC「版本发布」选手动发布,配合软启动节奏控制上线时刻。

---

## 2. ASC 隐私问卷(App Privacy)答案表

### 2.1 为什么空声明不行(已于 2026-08-15 修正)

`VoiceTodo/PrivacyInfo.xcprivacy` 曾是 `NSPrivacyCollectedDataTypes = 空`,依据是 TELEMETRY.md 的旧判断「不收集可识别数据」。但按 Apple 口径(数据离开设备**且被保留**即算 collected,瞬时处理除外),以下四处构成「保留」,需要声明:

1. **结构化结果缓存**: KV 存 ≤1 小时(`AIProxy/src/extractionCache.js`,TTL 3600s)
2. **订阅校验缓存**: `{tier, productId, expiresAt}` 按设备哈希存 KV,订阅期内(`AIProxy/worker.js` `sub:` key)
3. **遥测 D1**: 设备哈希 + 事件数据,90 天 GC
4. **反馈归档**: feedback-relay → D1 永久(手动删除)

低估声明的风险:上线后被 Apple 复查或被用户举报「隐私标签与实际不符」,后果是拒审/下架,远贵于如实声明。**声明不代表产品有问题**——全部是 App Functionality / Analytics 用途、不关联身份、不追踪,这在隐私标签里是最低敏感度的合规形态。

### 2.2 问卷答案(逐项)

| Data type | 分类 | Purpose | Linked to identity | Used for tracking |
|-----------|------|---------|--------------------|------------------|
| Device ID | Identifiers | App Functionality(配额/防滥用)+ Analytics(遥测 DAU/故障率) | No | No |
| Purchase History | Purchases | App Functionality(订阅权益校验) | No | No |
| Other User Content | User Content | App Functionality(转写处理+用户反馈) | No | No |
| Other Usage Data | Usage Data | Analytics(可靠性/产品改进) | No | No |

「追踪用户」总开关: **否**。

### 2.3 `PrivacyInfo.xcprivacy` 修正(已应用,随版本提交)

已于 2026-08-15 把空数组替换为下述内容(`VoiceTodo/PrivacyInfo.xcprivacy`,`NSPrivacyTracking=false` 不变):

```xml
<key>NSPrivacyCollectedDataTypes</key>
<array>
    <dict>
        <key>NSPrivacyCollectedDataType</key>
        <string>NSPrivacyCollectedDataTypeDeviceID</string>
        <key>NSPrivacyCollectedDataTypePurposes</key>
        <array>
            <string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
            <string>NSPrivacyCollectedDataTypePurposeAnalytics</string>
        </array>
        <key>NSPrivacyCollectedDataTypeIsLinked</key>
        <false/>
        <key>NSPrivacyCollectedDataTypeIsTracking</key>
        <false/>
    </dict>
    <dict>
        <key>NSPrivacyCollectedDataType</key>
        <string>NSPrivacyCollectedDataTypePurchaseHistory</string>
        <key>NSPrivacyCollectedDataTypePurposes</key>
        <array>
            <string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
        </array>
        <key>NSPrivacyCollectedDataTypeIsLinked</key>
        <false/>
        <key>NSPrivacyCollectedDataTypeIsTracking</key>
        <false/>
    </dict>
    <dict>
        <key>NSPrivacyCollectedDataType</key>
        <string>NSPrivacyCollectedDataTypeOtherUserContent</string>
        <key>NSPrivacyCollectedDataTypePurposes</key>
        <array>
            <string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
        </array>
        <key>NSPrivacyCollectedDataTypeIsLinked</key>
        <false/>
        <key>NSPrivacyCollectedDataTypeIsTracking</key>
        <false/>
    </dict>
    <dict>
        <key>NSPrivacyCollectedDataType</key>
        <string>NSPrivacyCollectedDataTypeOtherUsageData</string>
        <key>NSPrivacyCollectedDataTypePurposes</key>
        <array>
            <string>NSPrivacyCollectedDataTypePurposeAnalytics</string>
        </array>
        <key>NSPrivacyCollectedDataTypeIsLinked</key>
        <false/>
        <key>NSPrivacyCollectedDataTypeIsTracking</key>
        <false/>
    </dict>
</array>
```

`TELEMETRY.md` 的「App Store Connect 隐私问卷」章节已同步更新(2026-08-15,改为指向本表),两份内档口径一致。

---

## 3. IAP / 订阅配置清单(App Store Connect)

### 3.1 订阅组与产品

- [ ] 订阅组: `VoiceTodo Pro`(参考名,ASC 内部可见)
- [ ] 产品 1: `com.qingqingyu.voicetodo.pro.monthly` — 月订阅 **$4.99**(已有代码引用,`App/EntitlementManager.swift:17`,**ID 不可再改**)
- [ ] 产品 2: `com.qingqingyu.voicetodo.pro.yearly` — 年订阅 **$39.99**(`App/EntitlementManager.swift:18`)
- [ ] 两个产品都配 Intro Offer: Free Trial(天数见 §3.3)
- [ ] 本地化(至少 en): 显示名 + 描述,措辞与 paywall 一致(「higher daily AI allowance」,不写 unlimited)
- [ ] 分市场定价: 以 $4.99 美区为锚,ASC 自动换算后过一遍主要市场(GB/CA/AU/DE/FR/JP)有无离谱值
- [ ] 税务表单(ASC → 协议、税务和银行业务)已填,否则无法收订阅

### 3.2 本地调试

- 本地 `VoiceTodo/Products.storekit` 与 ASC 配置保持同步(trial 天数、价格),模拟器/真机 StoreKit 测试用它

### 3.3 ✅ trial 天数:已拍板 7 天(2026-08-15)

原冲突: PLAN 定 7 天 vs `Products.storekit` 3 天。**按 PLAN 决策 7 定稿,代码与文案已统一改为 7 天**(commit 见 git log)。

已同步(2026-08-15):
- `VoiceTodo/Products.storekit`: 月/年 intro offer `P3D` → `P7D`
- `Resources/Localizable.xcstrings`: `onboarding.pro.bullet.trial.title` / `paywall.card.trial_included` / `paywall.subtitle` 的 en + zh-Hans(无 ja 条目,与「日文不暴露」一致)
- `TERMS_OF_USE.md` §3、Review Notes §1
- 注: `paywall.cta.start_trial %@` 的天数本来就从 StoreKit 动态取,无需改

仍需人工(ASC 后台,代码管不到):
- [ ] ASC 两个产品的 Intro Offer 配 **7-day Free Trial**(上线前查一遍,与本地 storekit 配置漂移是拒审常见原因)
- [ ] `docs/onboarding-paywall-merge.md` 内的旧「3 天」字样属历史文档快照,不追改

### 3.4 服务端一致性

- [ ] `PAID_DAILY_LIMIT`(proxy)与 paywall 文案、Description 数字一致
- [ ] 订阅校验链路真机过一遍:购买 → 重启 app → 额度提升生效(走 `sub:` KV 缓存路径)
- [ ] 退款/过期路径:StoreKit2 transaction 状态变化后额度回退验证

---

## 4. ASC 必填 URL 字段

| ASC 字段 | 填什么 | 状态 |
|----------|--------|------|
| Privacy Policy URL(**必填**) | `https://[DOMAIN]/privacy` | 待域名(§5) |
| Terms of Use / EULA | 二选一: ① 用 Apple 标准 EULA(ASC 里直接勾,零维护) ② `https://[DOMAIN]/terms`(自定义,内容即 `TERMS_OF_USE.md`) | 建议先勾 Apple 标准 EULA 过审,自定义 Terms 作为增强后续再切 |
| App Support URL(**必填**) | 先用 `https://[DOMAIN]/`(落地页),后续可做 `/support` FAQ | 待域名 |
| Marketing URL(可选) | `https://[DOMAIN]/` | 软启动期可留空 |

订阅类 app 若不用 Apple 标准 EULA,则自定义 EULA 链接**必填**——两条路都通,别两处都空着。

---

## 5. 政策页落地(约 1 小时)

### 5.1 域名

1. 查可用性: `voicetodo.app` 首选(`.app` 强制 HTTPS,与政策页气质合)→ `getvoicetodo.com` → `voicetodoapp.com`
2. 注册商任意(Cloudflare Registrar 无加价,推荐),~$15-25/年
3. 顺手查一下 App Name/商标近似冲突,避免上线后被投诉改名

### 5.2 部署(Cloudflare Pages,免费)

```bash
# 一次性
npm install -g wrangler && wrangler login

# 把两个 MD 转成极简 HTML(任何 MD→HTML 工具均可,要求:
# 单文件、内联样式、移动端可读、<meta name="viewport">)
# 目录结构:
#   site/privacy.html   ← PRIVACY_POLICY.md
#   site/terms.html     ← TERMS_OF_USE.md

cd site && wrangler pages deploy . --project-name=voicetodo
# 绑定自定义域: Pages 项目 → Custom domains → [DOMAIN]
```

校验清单:
- [ ] `https://[DOMAIN]/privacy` 与 `/terms` 手机 Safari 打开可读
- [ ] 页内链接(如 Terms → Privacy)指向线上域名而非占位符
- [ ] `[BRACKET]` 全局搜索为 0 个
- [ ] 隐私政策里的 Apple 隐私政策外链可点

### 5.3 iCloud 别名

1. 设置 → [你的名字] → 登录与安全 → 登录 iCloud.com → 隐藏我的邮件 / 或直接注册新 iCloud 邮箱 `voicetodo@icloud.com`
2. 测试收发(尤其确认垃圾邮件过滤不吞用户来信)
3. 解析进两份政策 + ASC 联系方式 + `PROMOTION_COPY.md` §4.2 差评模板的 `[support email]`

---

## 6. 提交前一致性自检(扩展 PROMOTION_COPY.md §6 红线)

在 COPY §6 原 5 条之上新增/交叉引用:

- [ ] **trial 天数(已定 7)**: ASC Intro Offer 配置 = Products.storekit(P7D) = paywall UI = Review Notes = Terms §3 = Description(§3.3)
- [ ] **免费额度数字**: `DAILY_REQUEST_LIMIT` = Description = Review Notes = Terms `[FREE_TIER_PER_DAY]`(原红线 1 的扩展)
- [ ] **禁词 "unlimited"**: 全局搜索两份政策 + Description + paywall 文案 + ASC 产品显示名(原红线 2)
- [ ] **隐私口径三处一致**: `PRIVACY_POLICY.md` ↔ `PROMOTION_COPY.md` §4.3 ↔ Description 隐私段(均为「transcript 文本发服务器+AI 厂商,音频不存储」,不暗示 on-device AI / on-device 识别)
- [ ] **隐私标签 = 实际行为**: xcprivacy(§2.3)与 ASC 问卷答案(§2.2)逐项一致
- [ ] **审核可测性**: Review Notes 的 typed-path 说明与当版 UI 一致(输入框位置/交互若改版需同步)
- [ ] **政策页已上线且占位符清零**(§5.2 校验清单)
- [ ] **ASC 开发者名 = 政策署名 `[DEVELOPER_NAME]`**

---

## 附: 本文档发现的问题(处理状态)

1. ~~`PrivacyInfo.xcprivacy` 低估声明~~ → **已修正**(2026-08-15,§2.3 plist 已应用,随版本提交)
2. ~~trial 3 天/7 天冲突~~ → **已拍板 7 天并全局统一**(2026-08-15,§3.3;剩 ASC 后台人工配置一项)
3. ~~`TELEMETRY.md` 问卷章节与新口径矛盾~~ → **已修正**(2026-08-15,该章节改为指向 §2 答案表)

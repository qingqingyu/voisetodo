# App Store Connect 提审清单（v1.0 · zh + en）

> 创建于 2026-08-16。记录**需要人工在 App Store Connect 提交/填写**的全部表单，
> 以及提审前必须完成的人工动作。代码侧改动不在此文档范围。
> 完成一项勾一项；状态列供跟进。

---

## 0. 总览

| # | 表单/动作 | ASC 位置 | 关键内容 | 状态 |
|---|---|---|---|---|
| 1 | 创建 App 记录 | 我的 App → 新建 | 名称/Bundle ID/语言/SKU | ⬜ |
| 2 | App 信息 | App 信息 | **隐私政策 URL**、类别、关键词 | ⬜ |
| 3 | 版本信息 1.0 | 版本 → 1.0 | 截图、描述、技术支持 URL、审核备注、发布方式 | ⬜ |
| 4 | 定价与销售范围 | 定价与销售范围 | App 免费、地区 | ⬜ |
| 5 | 订阅商品 | 盈利 → 订阅 | 订阅组、2 商品、**3 天免费试用**、本地化 | ⬜ |
| 6 | App 隐私标签 | App 隐私 | 数据采集问卷（建议答案见 §6） | ⬜ |
| 7 | 年龄分级 | 年龄分级 | 问卷 → 4+ | ⬜ |
| 8 | 出口合规 | 版本页勾选 | 标准加密（HTTPS）豁免 | ⬜ |
| 9 | 沙盒测试 | 真机 Sandbox 账号 | 购买/取消/恢复/试用一次性 | ⬜ |
| 10 | 提交审核 | 版本页 | 最终检查后 Submit | ⬜ |

**前提条件（不满足无法开始）**
- [ ] Apple Developer Program 会员有效（$99/年，过期无法提审）
- [ ] 真机验证 Live Activity（fix 64caf21 之后装包验证锁屏/灵动岛）
- [ ] AIProxy 生产额度切换 + `LOG_HASH_SALT`（见 CONFIGURATION_CHECKLIST.md「上线前必做」，前置 P1 已全部修复）
- [ ] 隐私政策页可访问：https://qingqingyu.github.io/voicetodo-privacy/

---

## 1. 创建 App 记录

App Store Connect → 我的 App → ➕ 新建 App：

| 字段 | 填写值 |
|---|---|
| 平台 | iOS |
| 名称 | VoiceTodo（如被占用需换，全局唯一） |
| 主要语言 | 简体中文 |
| Bundle ID | `com.qingqingyu.voicetodo`（选择已注册的；无则先在开发者证书页注册） |
| SKU | `voicetodo-ios-1`（自定义，不对外展示，随意但唯一） |
| 完全访问权限 | 勾选（自己全权管理） |

---

## 2. App 信息

| 字段 | 填写值 | 备注 |
|---|---|---|
| **隐私政策 URL** | `https://qingqingyu.github.io/voicetodo-privacy/` | **必填，提审硬门槛**；与 Paywall 内链接同一地址 |
| 副标题（30 字内） | 例：「语音说出来，待办自动成」/ en: "Speak your todos into existence" | App 名下方灰字 |
| 主要类别 | 效率（Productivity） | |
| 次要类别 | 工具（Utilities）或留空 | |
| 关键词（100 字符内） | 例：`语音待办,提醒,日程,待办事项,语音输入,todo,reminder,voice` | 逗号分隔，不要重复类别词和 App 名 |

⚠️ 名称/副标题/关键词三处不要堆同一关键词，Apple 会以 2.3.7 拒审。

---

## 3. 版本信息（1.0）

### 3.1 截图 —— 先做一个决策

`project.yml` 未设 `TARGETED_DEVICE_FAMILY`，默认 **1,2（iPhone + iPad）**：

- **方案 A（推荐）**：只上 iPhone。改 `project.yml` 加 `TARGETED_DEVICE_FAMILY: "1"` → `xcodegen generate` 重新出包。只需 iPhone 截图。
- **方案 B**：保留 iPad。UI 未按 iPad 适配过（竖屏全屏、UIRequiresFullScreen），审核有被挑布局的风险，且需额外 13" iPad 截图 + 真机/模拟器过一遍。

**iPhone 必需截图**（6.9"，1320×2868 或 1290×2796，3~10 张）：

- [ ] 录音主界面（展示大按钮/月视图）
- [ ] 录音中 + 实时转写（Live Activity/灵动岛截图也可做宣传点）
- [ ] AI 提取确认页（ConfirmSheet，展示结构化待办）
- [ ] 待办列表/日历视图
- [ ] Onboarding 或 Widget（可选）

生成方式：模拟器 `xcrun simctl io booted screenshot 截图.png`，可用 `SIMCTL_APP_...` 快速装包；截图工具另见 temp/preview-screenshots 已有流程。

### 3.2 文案

| 字段 | 说明 |
|---|---|
| 描述（4000 字符） | 核心卖点：说话→AI 自动拆待办、日期时间识别、离线兜底、锁屏实时转写、Widget、日历写入。中英都要填（本地化语言列表里加 en） |
| 推广文本（170） | 可随时改不触发重审 |
| 新功能（1.0） | "首个版本" 一句话 |
| 版权 | `2026 qingqingyu` |
| **技术支持 URL** | **必填**。选项：① 复用 Pages 仓库加一个 support 页（找 Claude 一分钟加好）；② 暂填 `https://github.com/qingqingyu` |
| 营销 URL | 可留空 |

### 3.3 审核信息（App Review）

- 登录信息：**无需填写**（app 无账号体系），在备注里说明
- 联系人：姓名/邮箱/电话（填自己）
- 审核备注（可直接粘贴）：

```
VoiceTodo 是语音待办 app：用户说话 → 语音识别转写 → AI 提取结构化待办。

· 无需账号，无登录。请直接体验。
· 首次使用需授权麦克风 + 语音识别（Apple Speech framework），这是核心功能所需。
· 申请了 audio 后台模式：录音中锁屏后仍需继续采集（锁屏 Live Activity 展示实时转写）。
· AI 解析走我们自建 Cloudflare Worker 代理（key 不在客户端），每设备每日免费额度
  有限（当前测试期临时放大，上线前会收紧）。审核期间额度足够正常体验。
· 订阅（Pro）仅提高每日解析额度。付费墙内含隐私政策与使用条款链接、恢复购买按钮。
· App Store 上架后将立即切换生产额度配置。
```

- 版本发布方式：**建议「手动发布」**（首次上线时间可控），熟练后可改分阶段 7 天

---

## 4. 定价与销售范围

- [ ] App 价格：免费
- [ ] 销售范围：默认全部地区；确认包含 中国大陆 / 美国 / 日本（ja 未上但可卖 en 版）——或按意愿排除

---

## 5. 订阅（ASC → 盈利 → 订阅）

**必须与 `VoiceTodo/Products.storekit` 完全一致**，否则 app 线上拉不到商品：

| 项 | 值 |
|---|---|
| 订阅组名称 | `Pro` |
| 商品 1 | `com.qingqingyu.voicetodo.pro.monthly` · $12.99 · 1 个月 |
| 商品 2 | `com.qingqingyu.voicetodo.pro.yearly` · $98 · 1 年 |
| **介绍优惠（两个商品都要）** | **免费试用 3 天**（storekit: `free ×1 P3D`）。不配的话，线上永远不显示"开始 3 天免费试用"CTA |
| 商品本地化 | zh-Hans：`Pro 月度` / `Pro 年度` + 一句描述；en：`Pro Monthly` / `Pro Yearly` |
| 商品审核截图 | 每个商品 1 张付费墙截图（就用 3.1 里的 Paywall 截图） |

注意：ASC 价格按**销售地区税前/税后**展示，$12.99/$98 是美区基准价，其他地区 ASC 自动生成本地价（可再手动微调）。

---

## 6. App 隐私标签（问卷，建议答案）

按 app 实际行为（与隐私政策页一致）：

| 问题 | 答案 |
|---|---|
| 是否收集数据 | **是** |
| 数据类型 1：音频数据（Audio Data） | 用途：App 功能；与身份关联：**否**；用于追踪：**否** |
| 数据类型 2：诊断 → 使用数据（Usage Data） | 用途：App 功能（额度限制/产品改进）；关联：**否**；追踪：**否** |
| 数据类型 3：购买 → 购买历史（Purchase History） | 用途：App 功能（订阅状态）；关联：**否**；追踪：**否** |
| 数据类型 4：标识符 → 设备 ID（Device ID） | 加盐哈希后发给自建代理，按日保留用于额度限制。用途：App 功能；关联：**否**；追踪：**否**（与隐私政策页披露一致） |

不选"联系人/位置"。设备 ID 以加盐哈希形式传输，但按 Apple 定义（离设备传输 + 为当日额度计数而保留）仍属「收集」，需申报为 Identifiers → Device ID（不关联身份、不追踪）；若审核问起，答复见审核备注。

---

## 7. 年龄分级

问卷全部按实际：无暴力/色情/赌博/彩票/用户间内容分享（语音只进不出）→ 结果 **4+**。
有 Web 内容问题答"否"（app 无内嵌浏览器）。

---

## 8. 出口合规

版本页会问加密：
- Info.plist 已声明 `ITSAppUsesNonExemptEncryption = false`（仅 HTTPS 标准加密）
- ASC 问卷选择：**是，仅标准加密**（豁免，无需上传证明文件）

---

## 9. 沙盒测试（提审前，真机）

- [ ] 真机 → 设置 → 开发者 → Sandbox Apple Account，登一个小号
- [ ] 付费墙购买**月度** → 成功 → 取消续订（设置 → App Store → 沙盒账户管理）
- [ ] 删除 app 重装 → 恢复购买 → Pro 恢复
- [ ] 新沙盒账号首次进付费墙 → 显示「开始 3 天免费试用」（验证 intro offer）
- [ ] 同账号第二次 → 显示「订阅 Pro」（intro offer 一次性）

---

## 10. 提交审核（Submit for Review）

最终检查全部满足再点：

- [ ] §1~§9 全部勾完
- [ ] Xcode → Product → Archive → **Distribute App（App Store Connect）** 上传 1.0 (1) 构建
- [ ] ASC 版本页选中该构建
- [ ] 出口合规确认
- [ ] （可选）TestFlight 内测一天再提审
- [ ] **Submit for Review**
- [ ] 审核通过后：先去 Cloudflare 切生产额度（`wrangler.toml` 两值 + `wrangler secret put LOG_HASH_SALT` + deploy，见 CONFIGURATION_CHECKLIST.md），再点手动发布

---

## 附：审核被拒的高概率追问与答复口径

| 可能问题 | 口径 |
|---|---|
| 为什么要麦克风/语音识别 | 核心功能：语音转待办；引导见 onboarding |
| audio 后台模式用途 | 录音中锁屏继续采集，锁屏 Live Activity 展示进度 |
| 隐私政策在哪 | App 信息 URL + 付费墙内链接，同一地址 |
| 订阅没配条款链接 | 付费墙 legalLinks：隐私政策 + Apple 标准 EULA（3.1.2 合规） |
| 2.3.7 元数据堆砌 | 副标题/关键词避免重复 App 名与类别词 |

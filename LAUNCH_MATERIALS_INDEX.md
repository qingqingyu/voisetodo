# 上线材料索引(LAUNCH MATERIALS INDEX)

> 生成:2026-08-23 · 分支:main
> 本文件是全部宣传/提审材料的总入口:每个文件在哪、里面有什么、哪一版是权威。
> 新增上线材料时,在本文件登记一行;材料内容变更影响"权威性备注"时同步更新。

---

## 0. 快速导航(7 个文件全在仓库根目录)

| 文件 | 一句话 | 角色 |
|---|---|---|
| `PROMOTION_PLAN.md` | 软启动战略总纲 | 定方向、定 KPI、定约束 |
| `PROMOTION_COPY.md` | 对外文案手册 | 所有要说出口/贴出去的话 |
| `app-store-submit-checklist.md` | ASC 后台操作清单 | 提审当天照着勾的执行单 |
| `APPSTORE_REVIEW_KIT.md` | 提审材料包 | 材料从哪来、为什么这么填 |
| `PRIVACY_POLICY.md` | 隐私政策(EN 参考源) | 政策页内容依据 |
| `TERMS_OF_USE.md` | 使用条款(补充) | 订阅条款措辞依据 |
| `TELEMETRY.md` | 遥测设计文档 | 漏斗 KPI 的数据字典 |

所有文件路径 = 仓库根目录,与 `README.md`、`project.yml` 平级:

```
/Users/TWJ/工作/git/doflow/VoiceTodo/
```

⚠️ `.worktrees/xuanchuan/` 下有其中 6 个的**旧镜像**(无 `app-store-submit-checklist.md`,该文件是 main 上新写的)。看内容一律以主工作目录为准,worktree 副本勿更新。

---

## 1. 逐文件内容与状态

### 1.1 PROMOTION_PLAN.md — 战略总纲(9.0 KB)

章节:
- **§0 一句话战略**:Reddit 慢炖拉真实陌生用户,验证 install→Pro ≥5%
- **§1 战略骨架**:12 项决策表(渠道=App Store 软启动、市场=全球英文、定价=$4.99/mo·$39.99/yr·7 天 trial、过关线=4 周 ≥5%)
- **§2 上线前必做清单(Gating)**:2.1 工程(onboarding 改造/AI 成本/免费档 3/崩溃监控/英文母语审) · 2.2 Listing(wow 截图优先) · 2.3 基础设施(IAP/遥测/评论监控)
- **§3 4 周执行节奏**:Week 0 准备 → W1 r/iosapps → W2 r/getdisciplined → W3 r/productivity → W4 r/AppleiOS + 每周固定动作
- **§4 监控与 KPI**:漏斗七事件、每周指标表、4 周后决策树(≥5% 二波 / 3-5% 迭代 / <3% pivot)
- **§5 风险应对**:差评 24h 流程 / AI 成本熔断 /「Todoist 能做」话术 / Reddit ban 预防
- **§6 第二波渠道**:Product Hunt / X / HN(假设成立后)
- **附:4 条战略约束**:wow 必须在 paywall 前;TestFlight 不验证付费;日文市场不暴露;4 周硬线

状态:✅ 定稿(2026-08-14)。定价决策已落地(storekit $4.99/$39.99 + ASC 清单,2026-08-18 确认);trial 7 天已全链路对齐。AI 成本项:基线评测已跑(见 §4 备注,实为 GLM-4.7,成本前提待重算)。

### 1.2 PROMOTION_COPY.md — 对外文案手册(14.1 KB)

章节:
- **§1 核心信息**:1.1 One-liner(全渠道统一 H1) · 1.2 电梯稿(30s EN) · 1.3 **Wow demo 剧本(15s GIF 分镜,Week 0 制作)**
- **§2 App Store Listing(EN)**:2.1 Title/Subtitle/Keywords 字段 · 2.2 Description(前 3 行 hook) · 2.3 截图文案(6.9",前 3 张=wow)
- **§3 Reddit 帖子草稿**:4 sub × 4 周,每 sub 独立写,绝不 cross-post
- **§4 回应话术**:质疑应对模板(Todoist 对比等)
- **§5 上线日 Copy Checklist** · **§6 文案与产品一致性红线**(违反 = 拒审或差评)

状态:✅ 文案全部就绪。**素材未制作**:wow GIF、6.9" 截图本身还没拍/录。

### 1.3 app-store-submit-checklist.md — ASC 后台操作清单(9.9 KB)

章节:
- **§0 总览**:10 项表单勾选表 + 4 项前提(开发者会员/真机 Live Activity 验证/AIProxy 生产切换/隐私页可访问)
- **§1-§10**:创建 App 记录 → App 信息 → 版本信息(3.1 截图已拍板仅 iPhone · 3.3 审核备注可粘贴版) → 定价销售范围 → 订阅($4.99/$39.99 + Intro Offer 7 天) → 隐私标签 → 年龄分级 4+ → 出口合规 → 沙盒测试 → 提交审核
- **附:审核被拒追问口径**

状态:✅ 清单完整,**10 项全部未勾**。这是提审当天的执行单。

### 1.4 APPSTORE_REVIEW_KIT.md — 提审材料包(13.5 KB)

章节:
- **§0 占位符清单**:政策源文件中 `[BRACKET]` 占位符的解析状态
- **§1 Review Notes(EN)**:审核备注英文原文
- **§2 ASC 隐私问卷答案**:2.1 为什么空声明不行 · 2.2 逐项答案 · 2.3 xcprivacy 修正(已应用)
- **§3 IAP/订阅配置清单**:订阅组与产品 · 本地调试 · trial 已拍板 7 天 · 服务端一致性
- **§4 ASC 必填 URL 字段** · **§5 政策页落地(已完成,GitHub Pages 方案)** · **§6 一致性清单**

状态:⚠️ 与 checklist 部分重叠,**两处需以 checklist 为准**:①审核备注用 checklist §3.3 版(较新,含 audio 后台模式说明);②隐私问卷答案 §2.2 与 checklist §6 两套口径**尚未统一**(xcprivacy 口径 vs AudioData 口径,待拍板)。

### 1.5 PRIVACY_POLICY.md — 隐私政策 EN 参考源(7.9 KB)

章节:Summary / What VoiceTodo does / Data we handle(逐类:Speech and audio、Transcript、To-dos and calendar、Diagnostics、Feedback、Purchases+device ID)/ What we never do / Retention summary / Third parties / Your choices。

状态:⚠️ 定位已变:**正式发布源是 GitHub 仓库 `qingqingyu/voicetodo-privacy`**(Pages,中英双语,2026-08-16 上线,联系邮箱 334678754@qq.com)。本文件降级为"内容参考/英文全量版"——比 Pages 版更详细(点名 AI provider、feedback 留存期)。文内 `[DOMAIN]` 等占位符**不再需要解析**(域名方案已改为 GitHub Pages)。

### 1.6 TERMS_OF_USE.md — 使用条款补充(6.4 KB)

章节:What the app does / AI output disclaimer / Free tier and Pro subscription($4.99/$39.99/7 天)/ Offline behavior / Acceptable use / Changes / Third-party / Disclaimers / General / Contact。

状态:⚠️ 定位已变:App 内付费墙实际链接 **Apple 标准 EULA**(stdeula,见 `PaywallLegal.termsOfUseURL`),合规上够用。本文件作为**自定义补充条款**(公平使用上限措辞等)保留,非提审必需。金额已与 storekit 一致。

### 1.7 TELEMETRY.md — 遥测设计文档(8.1 KB)

章节:设计目标 / 架构 / 9 个核心事件(A 类功能使用 + B 类线上质量)/ PII 红线(绝不上报清单)/ ASC 隐私问卷 / **部署步骤(AIProxy)** / 查询示例 / 数据保留(90 天)/ 关闭遥测。

状态:⚠️ 文档就绪但 **D1 遥测未开通**(`AIProxy/wrangler.toml` 的 `TELEMETRY_DB` binding 仍注释,事件当前静默丢弃)。上线要靠漏斗 KPI 判 4 周过关,**开通 D1 = 上线前置**。部署步骤就在本文件内。

---

## 2. 相关联但**不属于**本次上线材料的

| 位置 | 是什么 | 为什么列出来 |
|---|---|---|
| `docs/mvp-japanese-launch/` | 日文市场专项计划 | 容易误认为上线材料;日文已拍板推迟 v1.1(PROMOTION_PLAN 附则 3) |
| `LogoConcepts/`(未进 git) | 3 张 logo 概念 png + 生成 json | 宣传**素材**,App 图标候选,非文档 |
| `AIProxy/eval/` | AI 成本评测工具(72 条 golden + runner) | PLAN §2.1 AI 成本项的配套;基线报告在 `AIProxy/eval/results/`(gitignored) |

## 3. 仓库外的上线材料

| 材料 | 位置 | 状态 |
|---|---|---|
| 隐私政策页(发布源) | GitHub 仓库 `qingqingyu/voicetodo-privacy` → `https://qingqingyu.github.io/voicetodo-privacy/` | ✅ 已上线(2026-08-16,中英双语) |
| App Store 商品/Intro Offer/隐私问卷 | App Store Connect 后台 | ⬜ 待配置(照 checklist §5/§6) |
| 生产 AIProxy(额度/订阅验签/遥测 D1) | Cloudflare Worker `voicetodo-ai-proxy` | ⬜ 生产部署停在 2026-07-24,8 月修复未上(含上线额度值 2/100、订阅验签 bundle 修复) |
| 技术支持 URL 页 | 计划复用 Pages 仓库加 support 一页纸 | ⬜ 未做(ASC 必填) |

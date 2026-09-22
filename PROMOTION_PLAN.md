# VoiceTodo · App Store 软启动宣传方案

> 分支: `xuanchuan` · 定稿: 2026-08-14
> 性质: 4 周软启动,验证核心假设「付费意愿」

## 0. 一句话战略

在英文市场 App Store 软启动,用 Reddit 慢炖拉真实陌生用户,验证「一句话拆多条」的 AI 待办能否转化 **≥5% install → Pro($4.99/mo)**。

## 1. 战略骨架(12 项决策)

| # | 决策点 | 结论 | 理由 |
|---|--------|------|------|
| 1 | 目标 | Beta 内测 + 反馈 + 证言(形式 = App Store 软启动) | 软启动拿真实数据,TestFlight 拿不到可信付费数据 |
| 2 | 核心楔子(UVP) | **一句话拆多条** | Apple Reminders/Todoist/TickTick 都做不到批量结构化(prompt 示例 18 是 wow 时刻) |
| 3 | 渠道性质 | 陌生人渠道 | 避开熟人 feedback bias |
| 4 | 核心假设 | **付费意愿** | 最 commercial 的假设;使用率/NPS 留给 GA 后 |
| 5 | 验证形式 | App Store 软启动(真实 IAP) | TestFlight sandbox 用户知道不扣钱,转化率虚高 3-5 倍 |
| 6 | 地区 | 全球英文市场 | 付费习惯最成熟;日文质量短板暂不暴露 |
| 7 | 定价 | Free 3/day, Pro $4.99/mo 或 $39.99/yr, 7-day trial | Todoist 锚定,转化数据有行业 reference |
| 8 | 过关标准 | **4 周 + install→Pro ≥5%** | 行业 median 2-5%,top tier 5-10%;4 周不拖不押 |
| 9 | Onboarding | Wow-first 三层漏斗 | wow 必须在 paywall 之前,否则测的是"为未知价值付费" |
| 10 | Listing | Wow 截图优先 | 前 3 张截图决定 60% install 转化 |
| 11 | Reddit 执行 | 小 sub 起步 +「I built」长帖 | 小 sub 容错高,大 sub 一击必中;4 sub × 4 周 |
| 12 | 差评应对 | 24h 公开回应 + 私下修复 | 评论不可逆且全球可见;回应态度本身是品牌 |

## 2. 上线前必做清单(Gating — 没做完不上线)

> 提审硬性材料(隐私政策 / 服务条款 / 审核备注 / 隐私标签答案 / IAP 配置清单)见 **`APPSTORE_REVIEW_KIT.md`**,政策源文件为 `PRIVACY_POLICY.md` / `TERMS_OF_USE.md`。§2.3 各项按该文档执行。

### 2.1 产品(工程)

- [x] **Onboarding 改造**(2026-08-18 实施,docs/onboarding-first-voice-trial.md):现状「权限 → 语言 → 付费页」已改为「权限 → 语言 → 首次录音 demo → wow → trial → paywall」。
  **与本文原目标序列的偏差(有意选择,已拍板)**:paywall 弹点在 **wow 播完后立即**(~2.3s),不等「第 2 次撞墙」——理由:free 3/day 配额下新用户首日只录 1–2 条,「第 2 次撞墙」在 day-1 不可达,而软启动只有 4 周度量窗口;且现状配额路径是首撞即弹(`quota_exhausted`),「第 2 次才弹」的触发点并不存在。弹点效果靠 `paywall_shown(source: first_wow / quota_exhausted)` 两列对照度量。付费页前置曾是战略 bug,本次已消除
- [x] **AI 成本控制**(unit economics,必须解决)——**已解决(2026-09-22,方案 A)**:
  - 风险(原状): Pro 100/day × Sonnet ≈ $15+/月成本 vs $4.99 收入 = 每 Pro 用户月亏 $10
  - **评测三轮结果(2026-09-22,72 条 golden)**:sonnet-p2 基线 95.7% / glm-4.6 95.7% / **glm-4.5-air 97.2%(en+zh 口径 98.1%,过 ≥98% 线;零 infra_error;en 满分;生产延迟 ~5.5-6s,比 Sonnet 快约 2×)**。air 按 `AIProxy/eval/README.md` §4.1 三关全过(全对率/与基线差距/日期重复组零回归),成本按 §5 表 **−93%**(Pro 月成本正常口径 $1.5,最坏口径 $4.3,对 $4.99 收入安全)
  - **生产落地(2026-09-22)**:wrangler.toml 新增 `ZAI_ANTHROPIC_AIR` provider(priority 3,默认不接流量),deploy 后经 admin 端点 `/v1/admin/providers/primary` 灰度切 primary → air。同批修复了 selector 对 admin override 静默失效的 bug(warm/cold 桶不看 priority,详见 selector.js 注释与 worker.test.js 钉头回归测试)。**回滚 = DELETE 该 override,秒级回 Sonnet**
  - 方案 B(限额)/C(提价)不再需要;失败 case 仅 2:zh-017(基线同错,归类判断题)、ja-014(README §6 已知「今度」歧义,ja 不 gate)
  - 评测工具:`AIProxy/eval/`(72 条 golden + 零依赖 runner)。运行窗口约束仍在:只能 UTC 周二/三/四跑
- [x] **免费档调整**: DAILY_REQUEST_LIMIT 2 → 3(与定价决策对齐;2026-08-30 已部署生效,文案侧均按 3 口径)
- [ ] **崩溃监控接入**:差评第一来源是崩溃
- [ ] 英文 copy 过类母语审(App 内所有英文文案)

### 2.2 App Store Listing

- [ ] 前 3 张截图:「一句话 → 5 条 todo」wow 时刻,大字标注(非 UI 界面)
- [ ] 后续截图: widget / 锁屏 Live Activity / 重复规则 / 多语言
- [ ] Title(30 字符): 含 voice/AI 关键词
- [ ] Subtitle(30 字符): wow 一句话
- [ ] Description: 前 3 行 hook + 关键词自然覆盖
- [ ] Keywords field: research voice todo / AI todo / spoken todo 竞品关键词

### 2.3 基础设施

- [ ] IAP 订阅配置(monthly/yearly + 7-day trial,App Store 审核 paywall 权益与 PAID_DAILY_LIMIT 一致性)
- [ ] App Store Connect: 评论回复权限、分市场定价
- [ ] 漏斗遥测事件确认: `install → first_record → wow_shown → quota_hit → trial_start → trial_end → paid`
- [ ] 评论监控通知(App Store Connect)

## 3. 4 周执行节奏

### Week 0(上线前 1-2 周准备期)

- 完成 §2 全部清单
- 写好 4 个 sub 的帖子草稿(每 sub 独立写,绝不 cross-post)— **草稿见 `PROMOTION_COPY.md` §3**
- 准备 wow GIF(15s demo,一句话拆 5 条)— **分镜见 `PROMOTION_COPY.md` §1.3**
- App Store 文案与截图 — **见 `PROMOTION_COPY.md` §2**

### Week 1: r/iosapps(16k,容错最高)

- 帖: "I built a voice-first todo app that turns one ramble into structured todos"
- 附 wow GIF + 2-3 个设计决策故事(为什么区分 user_explicit/title_mention、为什么枚举不本地化)
- 问开放性问题("What's your current capture flow?")
- 节奏: 发帖后 48h 内每条评论必回
- 记录: upvote / 评论数 / 点击 / install

### Week 2: r/getdisciplined(1.2M,GTD 强相关)

- 文案按 Week 1 反馈迭代
- 侧重「capture friction」痛点(GTD 人群核心痛)
- 更长的 why-I-built-this 故事

### Week 3: r/productivity(1.5M,最严)

- 发帖前必读 mod rules + 最近被删的 self-promo 帖
- 价值优先:分享具体工作流,app 作为工具出现而非主角
- 准备「Todoist 已经能做」话术(§5.3)

### Week 4: r/AppleiOS(300k)

- 侧重 iOS 原生体验: Widget / 锁屏 / Action Button / Siri
- 此时已 3 周迭代,产品最稳状态迎战最大泛流量

### 每周固定动作

- App Store 评论 24h 内公开回应(§5.1 流程)
- 数据汇总: installs / trial starts / Pro / AI proxy 成本
- 下周文案与产品迭代

## 4. 监控与 KPI

### 漏斗(AIProxy 遥测 + App Store Connect)

```
install → first_record → wow_shown → quota_hit(3/day 撞墙)
        → trial_start → trial_end → paid
```

### 关键指标(每周复盘)

| 指标 | 目标 | 数据源 |
|------|------|--------|
| install → first_record | >60% | telemetry |
| first_record → quota_hit | >30%(免费档紧度合适) | telemetry |
| quota_hit → trial_start | >40% | telemetry + IAP |
| trial → paid | >30% | App Store Connect |
| **install → Pro(净)** | **≥5% 过关线** | 综合 |
| AI 成本 / Pro 用户 | <$1/月 | proxy logs |
| App Store 评分 | ≥4.0 | App Store Connect |

### 4 周后决策树

- **≥5%**: 假设成立 → 第二波(§6)
- **3-5%**: 边缘 → 迭代 paywall 文案 / 价格 A/B,再测 2 周
- **<3%**: 假设不成立 → pivot 复盘(价格 / 楔子 / 受众三选一)

## 5. 风险与应对

### 5.1 差评(不可避免,流程化应对)

1. 24h 内公开回复:礼貌 + 具体回应批评点 + support 邮箱
2. 私下:复现 → 修 → 下版本修复
3. 修复后:在原评论追加回复告知已修复,邀请重评
4. 绝不:争辩 / 预埋好评(Apple 反作弊检测关联账号,有下架风险)

### 5.2 AI 成本失控

- GLOBAL_DAILY_LIMIT 全局熔断已有,按日预算反推设置
- 每日监控 proxy 成本,超预算即触发熔断
- Pro 用户量超预算时,优先降模型再考虑限额

### 5.3 「Todoist 已经能做」质疑(Reddit 必出现)

话术:不辩解,直接 demo。

> "Here's one 20-second ramble → 5 structured todos with dates, recurrence, categories, priorities. Happy to be shown wrong if Todoist does this — I couldn't find it."

语气:谦虚 + 具体事实,不 defensive。

### 5.4 Reddit ban

- 每个 sub 发帖前读 mod rules + 最近被删帖
- 遵守 10% self-promo rule(其余 90% 时间参与社区评论)
- 被 ban 记录原因,其他 sub 避免重复

## 6. 4 周后:第二波渠道(假设成立时)

| 渠道 | 时机 | 动作 |
|------|------|------|
| Product Hunt | Week 5-6 | 正式 launch 吃爆发流量(软启动验证过再打) |
| Twitter/X | 持续 | build in public,发数据/设计决策故事 |
| HN Show HN | Week 6+ | 技术角度(AIProxy 多 provider failover / prompt 工程) |
| 日文市场 | 数据好再扩 | 日文质量需先过母语审 |

## 附: 本方案钉死的战略约束(后续所有决策不得违反)

1. **Wow 必须在 paywall 之前** — onboarding 任何改动不得把付费页提前到首次录音 demo 之前
2. **TestFlight 不用于付费验证** — sandbox 数据不作数
3. **日文市场不在本方案范围** — 日文质量未过母语审前不主动暴露
4. **4 周 ≥5% 是硬线** — 到点看数据,该 pivot 就 pivot,不情怀加时

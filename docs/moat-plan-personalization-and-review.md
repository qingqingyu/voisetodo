# 技术方案：② 深层个性化解析 + ③ 沉淀/回顾（两条护城河落地）

> 本文档是交接用的实现方案，供另一位 AI / 开发者据此落地。
> 环境提示：Swift 代码需在 **Xcode 26** 编译验证（iOS 26 部署目标）；AIProxy(Worker) 的 JS 可用 `node --test AIProxy/worker.test.js` 验证。
> ② 的"自动学习"层严重依赖真机 + 真实用户数据长期迭代，不是一次做完的东西。

## Context
四点护城河评估：① 习惯回路（Action Button 一键录音 / 锁屏 widget / 灵动岛）已基本完成；④ 年付订阅机制已就绪。缺口在：
- **② 个性化解析** 只做到"识别层"——`UserVocabulary` 学高频词当 recognition hint，帮语音识别专有名词，但**不懂**用户的指代/隐含约定（"老地方"=某健身房、"交作业"=每周五）。这是"抄不走、越用越深"的中期差异点。
- **③ 沉淀/回顾** 基本空白——完成的待办只是划掉，没有周/月小结这类"回看资产"，迁移成本无从建立。

### 已核实的可复用基建
- **个性化注入管道**：`Protocols/UserVocabulary.swift`（词 + 频次，本地 UserDefaults / App Group）→ `NetworkClient` 请求体发 `vocabularyHints` → Worker `AIProxy/src/adapters/base.js` 的 `buildSystemPrompt` / `vocabularyHintPrompt` 注入 system prompt。
- **学习信号源**：`AppCoordinator.confirmTodos`（约 :440/:470/:573）触发 `vocabularyStore.learn(...)`，且此处能同时拿到 **原始 AI 提取 `extractedTodos`** 与 **用户确认后编辑的数组** → 可做 diff（高质量纠正信号）。
- **完成数据留存**：`TodoItem.completedAt` 永久留存（`TodoStore` 只 purge 过旧的 `VoiceCaptureRecord`，不清理完成待办）；规律任务完成在独立表 `TodoOccurrenceCompletion`（`completedAt` / `occurrenceDate`，分类取父任务）。
- **后台只读查询范式**：`TodoQueryActor`（P1，`@ModelActor`，fetch 失败显式抛）。
- **通知基建**：`App/LocalNotificationScheduler.swift` / `App/TodoNotificationSync.swift`（`NotificationScheduling` 协议）。
- Swift Charts **尚未引入**（回顾图表用系统自带 Swift Charts，无需第三方）。

---

## ② 深层个性化解析

**核心思路**：本地优先、确定性词库先行、把学到的东西作为结构化 hint 注入 prompt；"自动学"作为**建议层**（用户确认才生效），绝不偷偷改。复用现有 hint 注入管道，不引第三方 ML。

### A1 — 个人词库/约定（地基，确定性，先落）
- 新增 `PersonalGlossary`（仿 `UserVocabulary`，App Group 存储），两类条目：
  - **别名映射** alias → expansion：`"老地方" → "星光健身房"`、`"公司" → "XX 大厦"`。
  - **隐含约定** phrase → 默认时间/重复：`"交作业" → 每周五`、`"回头" → 3 天内`。
- **设置页"我的说法"**：手动增删条目（确定性、隐私本地、零 ML 风险、立刻生效）。复用 `HomeSettingsSheet` + `settings.personalization.*` 范式。
- **注入 prompt**：`NetworkClient` 请求体加一路 `personalHints`（结构化文本，如「用户约定：'老地方'指'星光健身房'；'交作业'通常安排在每周五」）；Worker `base.js` 加一段"用户个人约定"上下文（与 `vocabularyHints` 同注入范式），让 AI 展开别名 + 套用默认时间。
- **测试**：`worker.test.js` 断言 outgoing system prompt 含"个人约定"段。
- 效果：用户"教一次"，之后每次解析都懂——"越用越懂"的**显式版**。

### A2 — 从"确认修改"自动学习（魔法层，建议式，在 A1 之上）
- `AppCoordinator.confirmTodos` 里对每条做 **原始提取 vs 确认后** 的 diff（标题被改、时间被加/改、分类被改）。
- 本地频次表累计"同一表达被反复改成同一结果"：达阈值（如同一 alias → 同一 expansion 出现 ≥3 次）→ 轻量建议（toast/卡片）「你常把'老地方'改成'健身房'，记住吗？」→ 用户点"记住"才写入 A1 的 glossary。
- 时间约定同理：某短语确认后的 `dueHint`/`recurrence` 频次达阈值 → 提议记住默认时间。
- **决策权始终在用户**（建议 + 确认，不偷学），避免错误学习污染解析。这是最需真机 + 真实数据打磨的部分。

### A3 — 透明可控（隐私卖点，小）
- 设置页展示"App 学到的关于你的说法"列表，可编辑/删除（复用现有个性化开关 + 清除范式）。

**落地顺序**：A1（确定性词库 + 注入，零风险、立刻有价值）→ A2（自动学建议）→ A3（透明面板）。

---

## ③ 沉淀 / 回顾

纯聚合现有已留存数据，不新增数据采集。把"划掉即消失"变成"可回看的资产"。比 ② 直接得多——无 ML、无迁移。

### B1 — 回顾数据层（纯函数聚合，可单测）
- 新增 `ReviewAggregator`（纯函数，`Protocols/Domain/`）：输入 [完成事件] + 区间 → `ReviewSummary { total, byCategory: [TodoCategory: Int], byDay: [Date: Int], streakDays, busiestDay, completionRate }`。
- **完成事件来源 union**（关键，别漏别重）：`TodoItem where isCompleted`（按 `completedAt`）+ `TodoOccurrenceCompletion`（按 `completedAt`，分类取父任务）。
- store 加只读查询 `completedEvents(from:to:)`，下沉 `TodoQueryActor` 后台（仿 P1，fetch 失败显式抛）。
- 单测：分类占比、streak、区间边界、空区间、union 去重。

### B2 — 回顾界面（Review screen）
- 一个"回顾"视图。**入口**：设置页 + 首页顶部一张"本周小结"卡片（**别硬塞第三个底部 tab**，底部只留 today / calendar）。
- 展示：本周/本月完成数、**分类占比**（Swift Charts `SectorMark` 饼图 / 简单 bar）、**连续完成天数 streak**、最活跃的一天、完成趋势。周/月切换。
- 引入 **Swift Charts**（系统自带、iOS 26 可用，无第三方依赖）。

### B3 — 周期小结主动触达（把沉淀送到眼前）
- 每周一 / 每月 1 号本地通知（**复用现有 `NotificationScheduling` 基建**）：「本周完成 23 件，健康类最多 🎉」→ 点开进回顾页。
- 或首页顶部"上周小结"卡片（与 B2 入口合一）。

### B4 — 成就卡分享（可选，传播钩子）
- 用 SwiftUI `ImageRenderer` 把 `ReviewSummary` 渲成一张漂亮的"完成清单/成就"图，系统分享面板导出 → 小红书。接内容打法（"人生完成清单"）。标为可选 / later。

**落地顺序**：B1（聚合 + 查询，可单测）→ B2（回顾页 + 图表）→ B3（周期推送）→ B4（分享，可选）。

---

## 验证
- **JS（可跑）**：A1 的个人约定注入 → `node --test AIProxy/worker.test.js` 全绿 + 断言 prompt 含个人约定段。
- **Swift 单测（Xcode）**：`ReviewAggregator`（B1）、`PersonalGlossary` 命中/注入拼装（A1）纯逻辑断言。
- **Xcode + 真机手测**：
  - A1：设置里加"老地方 = 某健身房"→ 说"去老地方"→ 解析展开成该健身房。
  - A2：反复把某说法改成同一结果 → 出"记住吗"建议 → 记住后下次自动套用。
  - B1/B2：完成若干（含某天的规律任务）→ 回顾页数字/分类占比/streak 正确，union 不漏不重。
  - B3：到周一/月初收到小结通知，点开进回顾。

## 整体优先级建议
1. **A1**（个性化确定性词库，价值即时、零风险）
2. **B1 + B2**（回顾聚合 + 界面，纯读数据、直接见效）
3. **A2**（自动学习建议，魔法但慢工）
4. **B3 →（可选）B4 / A3**

## 不在本计划
- 服务端用户画像 / 云端个性化模型（坚持本地优先，隐私卖点）。
- 恢复被删的语音历史 tab（回顾是新的、聚合式的，不是旧历史流水）。
- 第三方图表 / ML 库（用系统 Swift Charts）。

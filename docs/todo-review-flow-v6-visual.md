# 复盘流程 v6 —— 视觉改版（A2 原型落地）

> 状态：**方案定稿 2026-10-14，未实施**。
> 原型：`docs/prototypes/review-flow-v6-a2.html`（浏览器打开即可点；右侧/「看改动」有逐步说明）。
> 前作：`docs/todo-review-flow-v5.md`（及 v1–v4，均已合 main）。
> 相关文件：`UI/Review/Flow/*.swift`、`UI/Review/RecapComponents.swift`、`Protocols/ReviewSessionStore.swift`、
> `Extractor/TodoExtractorService.swift`、`Resources/Localizable.xcstrings`。

## 一句话

**样子照 A2 原型改，逻辑一条不动。** 本轮只改视觉和少量文案，外加两个已确认的 bug（AI 草稿被截断、AI 草稿冒充用户笔记）。

原型里的数字、任务名都是示例数据；录音、拆小是模拟的。原型和本文冲突时，以本文为准。

---

## 0. 不许动的规则（逐条核对，改完自查）

这些是现有拍板，原型 A 曾改掉过，A2 已恢复。实施时**不得改变行为**：

| # | 规则 | 出处 |
|---|---|---|
| R1 | 数字来源与窗口不变：第 1 步「完成/新增」=上次复盘以来，「还挂着」=全部积压；第 3 步各卡自带窗口。**不加「上次 + 新增 − 完成 = 现在」算式** | v3 拍板 1、v5「确认不动」窗口三叉 |
| R2 | 第 2 步卡堆上限 `TriageRanking.deckSize = 8`，排序不变 | v2 拍板 1 |
| R3 | 第 2 步撤销**只覆盖「不做了」**；批量「推到稍后」有整批撤销 | v2 拍板 7 |
| R4 | 第 2 步尾部 ≥21 用户天批量出口、「余下 N 件这次不动」说明行照旧 | v5 拍板 3 |
| R5 | 第 2 步随时可进下一步（不处理也合法） | `canAdvanceCurrentStep` |
| R6 | 第 3 步所有卡照旧并存（规则卡、深读、地板 A/B/C、事实行、占位/阶梯提示、稀疏声明），出卡条件、冷却、跳步逻辑不变 | v4、v5 |
| R7 | 第 4 步最多选 3 件、至少选 1 件才能过（候选池空则放行） | 2026-08-22 拍板 |
| R8 | 第 5 步 AI 草稿**照旧预填**，用户一改标记即退场 | v5 拍板 2、D9 |
| R9 | 历次笔记全量、新→旧，最新一条带对照行 | 2026-08-23 拍板 5 |
| R10 | 下次复盘固定下周一，不可改 | v5 拍板 4 |
| R11 | `RecapHeroSection` / `RecapEvidenceRow` / `RecapStatCard` 与回顾页 `ReviewView` 共用：**回顾页外观零变化**（加参数或新建复盘专用视图） | 审阅缺口 A |
| R12 | `ReviewFlowView.swift` 不再增长：新视图代码放各自 `ReviewStep*.swift` | v5 S5 |

---

## 1. 全局视觉规则

1. **珊瑚色只给能点的东西**：主按钮、麦克风、「推到稍后」、文字按钮（撤销、展开）。所有**不可点**的标签（分类、信号强弱、AI 草稿标记、选中计数）用 `textSecondary` / `textMuted` + `subtleControlBackground`，不用 `primary` / `urgentText` / `warningText` 作底色、描边或文字。唯一例外：第 2 步「上次重点」chip 保留现有灰底 + `primaryText` 文字（它需要被注意到，且没有珊瑚底，不会被误认成按钮）。
2. **字号三级**：
   - 一级：每步最多一个，24pt 粗（`WarmFont.title(24)`）——第 1 步主标题、第 3 步第一张规则卡标题。
   - 二级：19pt（`WarmFont.headline(19)`）——第 5 步问题、第 2 步卡片标题（17→19）。
   - 三级：16pt（`WarmFont.headline(16)`）——卡片小标题。
   - 复盘流程内**不再使用 `serifDisplay`**（回顾页 `ReviewView` 保留，见 R11）。
3. **不截断正文**：复盘流程内承载内容的文字（标题、任务名、笔记、洞察正文、问题）去掉 `lineLimit(n) + minimumScaleFactor(0.7)`，改为 `.fixedSize(horizontal: false, vertical: true)` 自然换行。单行标签（chip、计数）可保留 `lineLimit(1)`。例外：第 1 步「上期你写了」保留 4 行折叠 + 点按展开（现有行为），但展开入口改成可见的文字按钮「展开全文 / 收起」。
4. **小标题（eyebrow）**：英文 12pt 大写加字距；中文、日文 13pt 不大写不加字距。
5. 卡片沿用 `RecapCard`，不改全局 `WarmRadius` token。
6. **大字号**：`dynamicTypeSize.isAccessibilitySize` 时，第 2 步四个按钮排成 2×2（先例：`HomeSelectedDayListView.swift:382`）；所有新增文字须在 AX5 下完整显示。

---

## 2. 逐步改动

### 第 1 步 回顾 `ReviewStepRecap.swift`（+ `RecapComponents.swift` 加参数，不改回顾页）

- 顶部口径行不变（「上次复盘以来」+「上次复盘：日期」）。
- **主卡**（有上次置顶时）：
  - 小标题「上次定的重点」【新键】。
  - 一级标题：`pinned_outcome_hero` 新文案（见 §4）。
  - 标题下逐条列出上次置顶的任务名（数据：`ReviewFlowState.lastPinnedIDs` + 本期 todos 快照），每行左侧 ✓（已完成，绿）/ ○（未完成），右侧灰字「做完了 / 还没做完」【新键】。任务名**不嵌进标题**。被删除的置顶任务不列（与 `lastPinnedOutcome` 计数口径保持一致，实施时核对）。
  - 无上次置顶时：回退现有 `.countSummary`（「完成了 N 件事」），字体改一级无衬线、颜色 `textPrimary`。
- **三个数字**：一行三块。「本期完成」「新增」普通白卡；「还挂着」稍宽、深色底（`textPrimary` 底 + `background` 字）作为本屏重点。下方一行灰色说明，左对前两块「上次复盘以来」，右对第三块「全部积压」【新键 ×2】。原 `review.stat.pending_note` 在复盘第 1 步不再显示（回顾页不受影响）。
- **当天完成**：「其中 N 件是当天记下、当天做完的」（三级标题）+ 判词（灰色正文）放进一张卡，出现条件不变（`showsSameDayLine` / `showsSameDayJudgment`）。
- **上期你写了**：引用样式不变；4 行折叠 + 「展开全文 / 收起」文字按钮【新键 ×2】。若该笔记是原样保存的 AI 草稿（§3.2），小标题旁加灰色 chip「AI 草稿（你保留的）」。

### 第 2 步 处理没做完的 `ReviewStepTriage.swift`

- 卡片：分类 chip、「上次重点」chip 保持现状（灰底；见 §1 第 1 条例外）。标题 17→19pt，最多 3 行改为不限行。推迟时间轴、语音原话照旧。
- 卡堆背后只露一条底边（不透出下一张内容）。
- **四个按钮同尺寸**：统一 56pt 圆（原为 56/44/44/56，v3 拍板 4 的「靠尺寸分层级」改为「靠颜色分」）。图标颜色：「不做了」`urgentText`，其余三个 `ink`（深灰）——**不再用 `primaryText`**（它在浅色下与红色太近）。标签不截断；AX5 下 2×2。
- 撤销：仍只对「不做了」（R3）。样式改为卡堆下方的深色提示条：「已划掉：任务名」+ 右侧文字按钮「撤销上一张」【新键：已划掉】。撤销后沿用现有 toast「已恢复」。
- 批量出口行、整批撤销、「余下 N 件这次不动」：逻辑和文案不变，样式对齐原型。
- **底部按钮两态**（仅第 2 步）：卡堆未清空时，主按钮改为白底次级样式，文案「剩下 N 张先留着，下一步」【新键，N=卡堆剩余张数】；卡堆清空后恢复珊瑚色主按钮「下一步」。点击行为都一样（R5）。

### 第 3 步 观察 `ReviewStepInsights.swift` / `InsightCardView.swift` / `InsightVizViews.swift`

- **顺序**调整为：规则卡（`rankedResults`）→ 深读卡 →「你的清单」卡 → 占位/阶梯提示 → 事实行 → 稀疏声明。代码注释已说明顺序不承载重要性；出卡条件全不变（R6）。
- **规则卡**：
  - 去掉右上角强度胶囊。强度改为底部样本说明行右侧的灰字 + 信号图标（三档文案不变：信号强/中/数据偏少），颜色一律 `textMuted`，不可点。
  - 第一张规则卡标题用一级字号，其余规则卡用二级。
  - 救火/计划卡（`.reactiveVsPlanned`）**不渲染 body**——标题已有百分比，比例条图例改为显示两组件数（「救火 20 · 计划 13」），样本说明照旧。其他规则卡 body 照旧。（解决「61% 在同一页出现两次」。）
- **「你的清单」卡**【新键：标题】：把地板 B（本期进出）、地板 A（年龄分布 + 最久 3 件 + 更多操作）、地板 C（积压集中在哪）合成**一张卡**，三段之间用细分隔线；某段为 nil 则不出该段，三段都 nil 则整卡不出。地板 B 段加小标题「上次复盘以来」。各段内容、文案、当场动作不变。实施方式：把三个 Floor 视图的外层 `RecapCard` 去掉，由新的组合卡包住。
- 深读卡：样式对齐原型（「AI 观察 · 来自你的数字」灰色小标题 + 正文），出现条件不变。

### 第 4 步 下周三件事 `ReviewStepCommit.swift`

- 分组改为「下周重点 n/3」与「也排在下周」【新键 ×2】：勾选的移到上组（按勾选顺序），未勾选的在下组。上组为空时显示一行灰字「点下面的任务，设为重点」【新键】。
- 每项标题下一行灰字写来源：本次排进来的用现有「你刚排进下周的」；原本就在下周的用「已排在下周」（**改现有键 `review.flow.commit.group.existing` 的值**，去掉「（还没选为重点）」）。
- 去掉选中序号（橙色「1」）和任何「Focus」标签；选中只用勾选圆圈表示。
- 选满 3 件后，其余项变灰不可点，下组标题右侧显示「最多选 3 件」【新键】。至少 1 件的闸门与 `gate_hint` 不变（R7）。

### 第 5 步 收尾账本 `ReviewStepLedger.swift` / `ReviewMicRow.swift`

- **顶部小结**：去掉卡片，改为一段左对齐文字：「你决定了 N 件」（三级）+ 明细一行灰字（今天做 · 拆小 · 下周 · 不做了 · 推后 · 置顶，零值不出）。**「推后 N」只在明细里出现一次**：`.decided` 态下不再单独渲染 `review.flow.ledger.someday_` 那一行（`.batchOnly` 态仍用它当主句）。`summary_caption` 去掉。全零态文案不变。
- **问问自己卡**，自上而下：小标题「问问自己」→ 二级标题 = 领域问题（`askDomainHintCategory` 有值时用 `ask.domain_hint`，无值时用「问问自己」本身作标题、不重复小标题）→ AI 草稿标记行（仅预填且未改动时，灰色 + 小星标，新文案见 §4）→ 输入框 → 灰字「下次复盘会给你看」。
- **麦克风**：从独立一行改为输入框右下角的珊瑚色实心圆按钮（≥44pt 点击区）。点一下开始录音（经 `ensureConsent`，与现在一样），按钮变停止键并有脉冲；输入框左下显示「在听…」+「取消」。再点一下 = 现有「说完了」（`finishRecording`）。静音自动停、错误降级、部分转写预填（E10）、追加换行等逻辑全部沿用 `ReviewMicRow` 现有实现，只换外观（可把 `ReviewMicRow` 拆成「状态机 + 两种外观」，拆小 sheet 的外观不变）。占位文案改为提到麦克风（§4）。
- **历次笔记卡**：去掉每条的 `lineLimit(4)`，全文显示；原样保存的 AI 草稿条目日期旁加 chip「AI 草稿（你保留的）」（§3.2）。此卡与回顾页共用 `ReviewNotesListView`，标记在两处都显示是预期行为。
- **下次复盘**：去掉卡片外观，改为居中一行灰字 + 时钟图标，不可点（R10）。

---

## 3. 两个 bug 修复（逻辑改动，单独 commit）

### 3.1 AI 草稿被截断成半个词

- 位置：`Extractor/TodoExtractorService.swift:319` `String(decoded.draft.prefix(DeepReadConfig.draftMaxLength))`，`draftMaxLength = 60`；英文提示词允许 ≤15 词，常超过 60 字符，出现「the weig」。
- 修法：超长时在上限内**最后一个句末标点 / 空格 / 中日文标点**处截断并去尾部空白；上限内找不到断点则**丢弃草稿（空串）**，不显示半截。不改提示词、不改上限数值（E11 与手打同尺）。
- 测试：英文超长（截在词边界）、中文超长（截在标点）、无断点（返回空）、未超长（原样）。

### 3.2 AI 草稿原样保存后被当成「用户写的」

- 现状：`ReviewStepLedger.prefillAIDraftIfNeeded` 注释写明「不再另设 noteSource 字段——保存即确认」，与 v5 D9「对质区只呈现用户确认内容或明示『AI 草稿（你保留的）』」不符。
- 修法：
  - `ReviewSession` 新增 `let voiceNoteIsUneditedAIDraft: Bool?`（合成 Codable，旧 payload 解码为 nil = 视为用户写的；先例 `factSignatures`）。
  - 收尾落库时（`ReviewFlowView.swift:1035` 附近）：保存的笔记 trim 后与 `deepReadResult.draft` trim 后**完全相同** → `true`，否则 `false`；笔记为空 → `nil`。
  - `ReviewNotesEntry` 带上该标记；`ReviewNotesListView` 与第 1 步「上期你写了」据此显示 chip。
- 测试：旧 payload 解码；三种保存情形（原样草稿 / 改过 / 空）；`ReviewNotesEntry.make` 透传标记。

---

## 4. 文案（`Resources/Localizable.xcstrings`，zh / en / ja 一个 commit 落地，E9）

改值（键不变）：

| 键 | zh | en | ja |
|---|---|---|---|
| `review.flow.recap.pinned_outcome_hero_%lld_%lld` | 上次定的 %1$lld 件重点，做完了 %2$lld 件 | You picked %1$lld to focus on. %2$lld done. | 前回決めた重点 %1$lld 件のうち、%2$lld 件が完了 |
| `review.flow.commit.group.existing` | 已排在下周 | Already on next week | 来週に入っている |
| `review.flow.note.draft.hint` | AI 草稿：可改可删。原样保存会标成「AI 草稿」 | AI draft: edit or clear it. Saved as-is, it stays marked as an AI draft | AI 下書き：編集・削除できます。そのまま保存すると「AI 下書き」と表示されます |
| `review.flow.insights.ask.placeholder` | 随便写两句，或点麦克风说 | A line or two, or tap the mic | 二、三行で。マイクで話しても OK |

新键：

| 键 | zh | en | ja |
|---|---|---|---|
| `review.flow.recap.pinned.title` | 上次定的重点 | Last time’s focus | 前回の重点 |
| `review.flow.recap.pinned.done` | 做完了 | Done | 完了 |
| `review.flow.recap.pinned.open` | 还没做完 | Not yet | 未完了 |
| `review.flow.recap.stats.window` | 上次复盘以来 | Since last review | 前回の振り返り以降 |
| `review.flow.recap.stats.backlog` | 全部积压 | Whole backlog | 未完了すべて |
| `review.flow.recap.last_note.expand` | 展开全文 | Show all | 全文を表示 |
| `review.flow.recap.last_note.collapse` | 收起 | Show less | 閉じる |
| `review.flow.triage.dropped_%@` | 已划掉：%@ | Dropped: %@ | やめた：%@ |
| `review.flow.triage.next_leave_%lld` | 剩下 %lld 张先留着，下一步 | Leave the other %lld for now | 残り %lld 枚はそのままで次へ |
| `review.flow.insights.list.title` | 你的清单 | Your list | あなたのリスト |
| `review.flow.commit.group.focus` | 下周重点 | Focus | 来週の重点 |
| `review.flow.commit.group.others` | 也排在下周 | Also next week | ほかの来週分 |
| `review.flow.commit.tap_to_focus` | 点下面的任务，设为重点 | Tap a task below to make it a focus | 下のタスクをタップして重点に |
| `review.flow.commit.cap_hint` | 最多选 3 件 | Up to 3 | 最大 3 件 |
| `review.flow.note.mic.a11y` | 用语音回答 | Answer by voice | 音声で答える |
| `review.notes.ai_kept` | AI 草稿（你保留的） | AI draft (you kept it) | AI 下書き（そのまま保存） |

英文有单复数的键（`next_leave`）按现有 plural variations 写 one/other。ja 文案如与现有语气不一致，可小改，但不要留空。

不再在复盘流程中使用（键保留，回顾页或别处仍可能用）：`review.stat.pending_note_%lld`（复盘第 1 步）、`review.flow.ledger.summary_caption`、`review.flow.note.mic.hint`。删除键前先全局搜索确认无引用。

---

## 5. 验收

1. **构建与测试**：项目现有单测全部通过；新增 §3 的单测。
2. **规则自查**：逐条对照 §0 R1–R12，在 PR 描述里写明每条如何保持。
3. **截图**：第 1–5 步 × zh / en / ja × 浅色 / 深色，加 zh 的 AX5 一组（重点：第 2 步 2×2、第 1 步标题、第 5 步问题和输入框）。与原型对照。
4. **回顾页不变**：`ReviewView` 改动前后截图一致（R11）。
5. **边界态**：无上次置顶（回退完成数标题）；第 4 步候选池为空；第 5 步无领域提示、无 AI 草稿、笔记为空；第 3 步地板 B 为 nil 时「你的清单」只剩两段。

## 6. 不在本轮

- 修改复盘日期、How we know 说明面板、「所有数字一个快照」（原型 A 的提议，已否）。
- 数字口径统一（如要做，单独拍板）。
- 首页及其他页面的视觉。

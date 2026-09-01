# 方案：完成待办的正反馈（分级制）

> 状态：**已拍板，未实施**（2026-08-31 经九轮 grill-me 拍板；2026-09-01 代码复核后修订三项，见文末「代码复核与拍板修订」）。
> 核心结论：分级制反馈——**常规完成**（每件）= light 触感 + 勾号原地「点+星」爆花 + checkbox 弹跳；**大庆祝**（仅今日清空）= success 触感 + 全屏彩带 + 中央文案 toast。取消完成仅轻 selection。**V1 无音效**。全自绘（Canvas/TimelineView），零第三方依赖。
> 行号基线：`aac75f9`（现状盘点已在 `22236f7` 复核，结论不变）。

---

## 现状盘点（拍板前代码事实）

1. **主列表勾选零触感**：`UI/Home/HomeView.swift:82-113` 的 `toggleTodo` / `toggleOccurrence` 只做 `withAnimation(WarmAnimation.springSmooth)` + 落库，无任何 haptic。
2. **触感基建已存在**：`UI/Shared/Haptics.swift` 提供 selection / success / warning / error / light / medium 六档。ConfirmSheet 确认（`ConfirmSheetView.swift:459`）、复盘流（`ReviewStepTriage` 多处）、月历格按钮（`HomeMonthGridButton.swift:145`）、context menu（`WarmTodoCard.swift:393/403`）都在用——唯独最高频的「完成」没用。
3. **checkbox 已有微动画基底**：`UI/Home/WarmTodoCard.swift:243-266`——绿圈填充（0.2s easeInOut）+ `WarmCheckmarkShape` 勾号 trim 描画（0.3s）+ 标题划线。
4. **Onboarding 已有静态彩带插画**（`App/OnboardingView.swift:1260` confettiPiece，纯装饰非粒子）。
5. **入口汇聚点**：`UnscheduledDrawer` / `HomeSelectedDayListView` / `PendingDateTodoRow` 的勾选都转发到 `HomeView.toggleTodo / toggleOccurrence`——Home 内一处挂载全入口生效。独立入口：详情页 Mark as Done（`App/AppCoordinator.swift:891`）、复盘流（自带触感体系）、Widget（独立进程，自定义触感/动画管不到）。

---

## 拍板决定（九问九答）

### 1. 强度策略：分级制

- 常规完成给中档反馈（触感 + 原地爆花）；**里程碑才上大庆祝（彩带 + toast，修订 1 后无音效）**。
- **Why**：工具型 app 高频操作，每次全屏彩带第三次就成噪音；大庆祝靠稀缺性撑价值。全 app 已有 Things 3 式极简语言，每件都大庆祝违和。
- 已否决：每件都一样中等强度 / 每件都大庆祝 / 只做里程碑。

### 2. 常规档配方：触感 + 爆花 + 弹跳

| 层 | 内容 | 时机 |
|---|---|---|
| 触感 | `HapticFeedback.light()`（**修订 2**：原定 `.success()`，改轻档让触感也跟着分级；`.success()` 让位给今日清空） | tap 瞬间 |
| 爆花 | 见第 4 条 | 勾号描画完成后接力（tap 后 ~150-250ms） |
| 弹跳 | checkbox 本体 `WarmAnimation.springBouncy` 放大回弹 | 与爆花同步 |

- 已否决：只加触感（改动最小但爽感不足）、触感+弹跳无粒子（弱一档）。
- **修订 2 之后**：常规档 `.light()` / 大庆祝 `.success()`，触感层与视觉层同步分级。原方案两档共用 `.success()`，触感层实际没有分级，与分级制主张自相矛盾（理由详见文末修订表）。

### 3. 入口覆盖：Home 全量 + 详情页仅触感

- Home 列表全入口（含抽屉/选日列表，共用 `toggleTodo`/`toggleOccurrence`）挂完整配方。
- ⚠️ **「全入口」对触感成立，对爆花不成立**：触感挂 `toggleTodo` 动作层，天然覆盖全部入口；爆花挂视图层，而「待定日期」分区的 `PendingDateTodoRow` 有自己手写的 checkbox，不是 `WarmTodoCard`。见文末复核 B——按顶层 overlay + anchor 方案实现后，该行也上报 anchor 即可统一。
- 详情页 Mark as Done **只加触感不加爆花**——页面随即关闭，爆花看不到。
- 复盘流已有密集触感体系，**不动**（再叠加会双重震动）。
- Widget 独立进程，管不到。

### 4. 爆花样式：点 + 星混合放射

- 从 checkbox 圆圈边缘放射 **7±2 颗圆点 + 1-2 颗四角小星**；颜色 = `WarmTheme.success` 绿 + 该条**分类色**（每种类别爆出来的颜色都不同，与卡片「分类色 checkbox」语言一致的隐藏彩蛋）。
- 初速度放射状带随机扰动，ease-out 减速飞散后淡出，全程 ~500ms；外圈一圈**细涟漪**框出爆点。
- 点负责「爆」、星负责「趣」、涟漪负责「起点」，三层同帧。
- **时机是接力不是抢戏**：勾号 trim 描画（0.3s）占完成感前半段，爆花在其后爆开。
- 已否决：纯圆点（第二周就 invisible）、迷你纸屑（24pt 尺度旋转矩形糊）、纯涟漪（强度只等于动画化确认）。

### 5. 大庆祝触发：仅「今日清空」

- 定义：勾选落库后，当日待办从 **>0 → 0 的转换瞬间**。
- 每次转换都触发（自然行为下一天最多一两次）；当天本来 0 件不触发。
- **Why**：触发明确、心智直觉（「清空今天」本身是成就）、检测成本低（落库后查当日 pending）。
- ⚠️ 「当日」「待办」「转换」三个词各有一个坑，口径已钉死，见文末复核「四处必须钉死的口径」1–4 条——实现前先读那四条，不要按字面自由发挥。
- 已否决（V2 候选）：连续打卡 N 天（需统计历史，习惯激励更强但实现重）；高优先级完成（一天多次，不稀缺）。

### 6. 大庆祝形式：全屏彩带 + 文案 toast

- **彩带**：顶部撒落 20-30 片分类色 + 暖色纸条，1.5s，`.allowsHitTesting(false)` 纯视觉不挡交互（清空瞬间用户可能马上离 app，不能挡路）。
- **文案**：中央短暂浮现一行庆祝文案（如「今天全部完成」，zh/en/ja 三语），复用 Toast 视觉语言，2s 自动消失。
- **触感**：`HapticFeedback.success()`（修订 2 从常规档让位过来）——与彩带同时起，作为大庆祝的触感标记。
- 已否决：原点大爆发（易被误认为大一号常规反馈）、小烟花（语言偏重大事件+实现最重）、插画卡片（需设计资产+三语适配，风格风险最大）。

### 7. 声音：~~仅清空时轻音效~~ → **V1 不做（修订 1）**

- **V1 全程无声**，常规完成和今日清空都不播音效。彩带 + 中央 toast + success 触感已足够撑「稀缺大庆祝」。
- **Why 砍掉**：全 app 目前零音频播放代码，而 `Voice/AudioSessionHelper.swift:21` 已把 session 占为 `.record` 并 `setActive(true)`。加播放要一并处理「录音中不播」「播完不能盲目 `setActive(false)`，否则掐掉录音会话」「`.record` ↔ `.ambient` 切换时序」——为一声「叮」引入整套音频会话协调，成本远超收益。
- **原文「必须自己判断静音开关」是做不到的**：iOS 没有读取静音开关位置的公开 API。正确机制是把 category 设成 `AVAudioSession.Category.ambient`，由系统按开关静音、且不打断用户正在放的音乐。
- V2 若要加：用 `.ambient`，录音期间跳过，且必须同时补一个关闭开关（见 §9）。
- 已否决（原九轮）：常规也「叮」（办公/深夜高频骚扰）、真实鼓掌声（与极简语言搭不搭存疑）。

### 8. 取消完成（uncheck）：仅轻 selection

- 取消勾选只给 `HapticFeedback.selection()`（与 hover/picker 同档）+ 现有动画回退（绿圈消失、勾号反向描画），无粒子。
- **Why**：取消是修正不是成就，给反馈会稀释「完成」的正反馈对比度。
- 已否决：完全无反馈（双向手感不一致）、warning 触感/灰色粒子（惩罚感让用户犹豫纠正误勾）。

### 9. 设置项：V1 不做，随 Reduce Motion

- 不加 app 内开关，尊重系统 Reduce Motion：`@Environment(\.accessibilityReduceMotion)` 开启时，爆花降级为仅触感、彩带降级为仅文案 toast。
- **Why**：设置页膨胀成本 > 收益；会去关它的用户比例预计很小，等真实反馈再决定。
- **修订 3（理由补强）**：原理由链有个漏洞——`accessibilityReduceMotion` 只覆盖动效，开了它的用户照样听得见音效，而「不加开关」= 用户没有任何关闭手段。修订 1 砍掉音效后该漏洞自动消失，「不加开关」的结论才真正成立。**所以 V2 一旦加回音效，必须同时加开关**，两件事绑死。
- 触感**不**随 Reduce Motion 降级，这是刻意的：系统触感总开关在「声音与触感」里，app 无公开 API 读取，也不该二次拦截。
- 已否决：单一总开关、触感/视觉/声音三档独立开关（V1 过重）。

---

## 实现要点

- **零第三方依赖**（用户全局规则）：粒子/彩带全用 `Canvas` + `TimelineView` 自绘。
- **爆花锚点：anchor preference + HomeView 顶层 overlay，不要挂在行内**（复核 A/B 的结论，这是与原方案最大的差别）：
  - checkbox 上挂 `.anchorPreference(key:value:.bounds)` 上报边界；`HomeView` 用 `.overlayPreferenceValue` 在顶层 overlay 画 Canvas 粒子。
  - 挂行内会被 `List` 行裁掉（`HomeSelectedDayListView.swift:56`），且覆盖不到 `PendingDateTodoRow` 自己那套 checkbox。
  - 顺带收益：粒子层与行的生命周期解耦，行滚出屏幕不会把动画掐断。
  - 触感仍挂 `toggleTodo` / `toggleOccurrence` 动作层（那一层天然全入口覆盖）。
- **今日清空检测**：只在 `toggleComplete` **成功返回后**判断，不是定时轮询、**也不是**监听「当日 pending 数变 0」的状态（口径 3：那会让「不做了」也放彩带）。当日待办数直接复用 `HomeView.selectedDayStats()`（`:987`），不另写一套（口径 2）。触发前先过 `DayClock.isSameUserDay(selectedDate, Date())`（口径 1）。
- **UI 测试防护**：粒子/彩带层 `.allowsHitTesting(false)` + 不加 a11y identifier；再补 `.accessibilityHidden(true)`——挂到顶层 overlay 后它会进入 a11y 树，光靠「不加 identifier」不足以让元素查询忽略它。
- **三语文案**：庆祝 toast 文案进 `Localizable.xcstrings`（zh/en/ja，MVP 语言范围）。V1 无音效，无 asset 与版权事项。
- **连续快速勾选**：每个爆花实例带独立 id，天然无冲突；参考 `NumberPopModifier` 的 generation 比对防竞写写法。顶层 overlay 需要维护一个「进行中的爆花」集合而不是单个 `@State`，否则连点会互相打断。

---

## 代码复核与拍板修订（2026-09-01，复核基线 `22236f7`）

### 核实结论

「现状盘点」5 条在最新代码上**全部属实**，仅两处引用订正（不影响任何结论）：

- `confettiPiece` 实际定义在 `App/OnboardingView.swift:1289`，`:1260` 是调用它的 `celebrationIllustration`。
- `toggleTodo` 现在 `HomeView.swift:82`、`toggleOccurrence` 在 `:98`，区间尾部比原文的 `82-113` 略有位移。

复核另确认一条原文未提、但决定了修订 1 的事实：**全 app 目前零音频播放代码**（`AVAudioPlayer` / `AudioServicesPlaySystemSound` 全库无命中），且 `Voice/AudioSessionHelper.swift:21` 已把 audio session 占为 `.record` 并 `setActive(true)`。

### 三处会让实现做歪的问题

**A. 爆花锚点不能挂在 `WarmTodoCard` checkbox 层——会被 List 行裁掉**

`UI/Home/HomeSelectedDayListView.swift:56` 是 `List {`，SwiftUI 的 List 行把内容裁到行边界。行高 56–76pt（`WarmSize.rowCompact` / `rowTall`），而爆花是从 44pt checkbox 放射、飞散约 500ms——大半会被切掉。要想不被裁，半径得压到 25pt 以内，那已经不是「爆花」了。

**改法**见「实现要点」第 2 条：anchor preference 上报 + `HomeView` 顶层 overlay 绘制。HomeView 已有 `.overlay(alignment: .top)`（glossary banner）可作参照层。

**B. `PendingDateTodoRow` 有自己的 checkbox，行内锚点覆盖不到**

`UI/Home/PendingDateTodoRow.swift:51-66` 是一套手写 checkbox，不是 `WarmTodoCard`：静态 `Circle` + `.opacity(0)` 的填充圈，**既没有 `WarmCheckmarkShape`、也没有 trim 描画动画**。所以 §2 定的「勾号描画完成后接力（~150-250ms）」这个时机，在「待定日期」分区根本不存在。

`UnscheduledDrawer.swift:237` 用的是 `WarmTodoCard`，无此问题——缺口只有 `PendingDateTodoRow` 一处。改法 A 落地后该行也上报 anchor 即可统一；勾号接力时机在那里退化为 tap 后固定延时（或顺手把它的 checkbox 抽成与 `WarmTodoCard` 共用的组件，二选一）。

**C. 「自己判断静音开关」是做不到的**

iOS 没有读取静音开关位置的公开 API。正确机制是 `AVAudioSession.Category.ambient`——由系统按开关静音，且不打断用户正在放的音乐。已由修订 1 消解（V1 不做音效），此处保留记录，避免 V2 重蹈。

### 四处必须钉死的口径

§5「勾选落库后，当日待办从 >0 → 0 的转换瞬间」——这句话里「当日」「待办」「转换」各埋一个坑：

1. **「当日」= 真今天，不是 `selectedDate`**。`HomeView.swift:987` 的 `selectedDayStats()` 是按 `selectedDate` 算的。用户翻到上周补做历史任务、勾完那天最后一条，按字面实现会放彩带。触发条件必须加 `DayClock.isSameUserDay(selectedDate, Date())`。
2. **「待办」的分母直接复用 `selectedDayStats()`，不另写**。它的口径是「当日 occurrence（含规律任务、跨天事件中间日）+ 今日完成的无日期任务」，**不含**「稍后」/「待定日期」/「没能识别」三个分区的未完成项。这与顶部进度圆环（`HomeView.swift:794` `progressBarRow`）同源，所以「清空」= 圆环走满，用户心智一致。另写一套必然与圆环对不上，出现「圆环满了却没彩带」或反过来。
3. **「转换」只认 `toggleComplete` 成功后的检测，不能挂在「当日 pending 数变 0」的状态上**。复盘第 2 步的 `TodoStore.abandon`（`:377`）也会让当日 pending 归零。挂状态就变成**划掉换彩带**——正好通了 `docs/todo-review-flow-design.md` 拍板 1 花力气堵死的那条 gaming 路径。
4. **详情页 / Widget 造成的清空不补放**。只在 Home 前台 `toggleTodo` / `toggleOccurrence` 路径触发；详情页勾完即关页、Widget 是独立进程，回到 Home 一律不补彩带。写下来，避免日后被当 bug 报。

### 三项拍板修订

| # | 原决定 | 修订后 | 理由 |
|---|---|---|---|
| **修订 1**（§7、§6、§1） | 今日清空播一声 CC0 轻音效 | **V1 不做音效** | 全 app 零音频播放代码，`AudioSessionHelper` 已占 `.record` 且 `setActive(true)`。加播放要一并处理「录音中不播」「播完不能盲目 `setActive(false)`，否则掐掉录音会话」「`.record` ↔ `.ambient` 切换时序」——为一声「叮」引入整套音频会话协调，成本远超收益。彩带 + toast + success 触感已足够撑「稀缺大庆祝」。 |
| **修订 2**（§2、§6） | 常规完成用 `HapticFeedback.success()` | **常规完成 `.light()`**，`.success()` 让位给今日清空 | 原方案两档共用 `.success()`，**触感层根本没有分级**，与「分级制」这个核心主张自相矛盾。且 `UINotificationFeedbackGenerator(.success)` 是三连震模式（约 0.5s）：勾待办是全 app 最高频操作（一天几十次），ConfirmSheet 确认是一批一次——两种频次不该同档；连续快速勾选时通知型 haptic 还会互相盖掉。改后触感与视觉同步分级。 |
| **修订 3**（§9） | 随 Reduce Motion 降级，不加 app 内开关 | **维持不加开关**，但理由链补强 + 绑定 V2 条件 | 原理由链有漏洞：`accessibilityReduceMotion` 只覆盖动效，开了它的用户照样听得见音效，而不加开关 = 用户没有任何关闭手段。修订 1 砍掉音效后漏洞自动消失，结论才真正成立。**因此 V2 一旦加回音效，必须同时加开关**，两件事绑死。 |

### 未改动的部分

分级制本身（§1）、爆花配方（§4，点+星+涟漪+分类色，在顶层 overlay 方案下完全可行）、大庆祝触发选「今日清空」而非连续打卡（§5）、取消完成只给 selection（§8）、`.allowsHitTesting(false)`、参考 `NumberPopModifier` 防竞写——复核认为均成立，不动。

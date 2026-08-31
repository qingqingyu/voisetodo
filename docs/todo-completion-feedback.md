# 方案：完成待办的正反馈（分级制）

> 状态：**已拍板，未实施**（2026-08-31 经九轮 grill-me 拍板）。
> 核心结论：分级制反馈——**常规完成**（每件）= success 触感 + 勾号原地「点+星」爆花 + checkbox 弹跳；**大庆祝**（仅今日清空）= 全屏彩带 + 中央文案 toast + 轻音效。取消完成仅轻 selection。全自绘（Canvas/TimelineView），零第三方依赖。
> 行号基线：`aac75f9`。

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

- 常规完成给中档反馈（触感 + 原地爆花）；**里程碑才上大庆祝（彩带/音效）**。
- **Why**：工具型 app 高频操作，每次全屏彩带第三次就成噪音；大庆祝靠稀缺性撑价值。全 app 已有 Things 3 式极简语言，每件都大庆祝违和。
- 已否决：每件都一样中等强度 / 每件都大庆祝 / 只做里程碑。

### 2. 常规档配方：触感 + 爆花 + 弹跳

| 层 | 内容 | 时机 |
|---|---|---|
| 触感 | `HapticFeedback.success()`（复用基建，与 ConfirmSheet 确认同档，全 app 触感语言统一） | tap 瞬间 |
| 爆花 | 见第 4 条 | 勾号描画完成后接力（tap 后 ~150-250ms） |
| 弹跳 | checkbox 本体 `WarmAnimation.springBouncy` 放大回弹 | 与爆花同步 |

- 已否决：只加触感（改动最小但爽感不足）、触感+弹跳无粒子（弱一档）。

### 3. 入口覆盖：Home 全量 + 详情页仅触感

- Home 列表全入口（含抽屉/选日列表，共用 `toggleTodo`/`toggleOccurrence`）挂完整配方。
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
- 已否决（V2 候选）：连续打卡 N 天（需统计历史，习惯激励更强但实现重）；高优先级完成（一天多次，不稀缺）。

### 6. 大庆祝形式：全屏彩带 + 文案 toast

- **彩带**：顶部撒落 20-30 片分类色 + 暖色纸条，1.5s，`.allowsHitTesting(false)` 纯视觉不挡交互（清空瞬间用户可能马上离 app，不能挡路）。
- **文案**：中央短暂浮现一行庆祝文案（如「今天全部完成」，zh/en/ja 三语），复用 Toast 视觉语言，2s 自动消失。
- 已否决：原点大爆发（易被误认为大一号常规反馈）、小烟花（语言偏重大事件+实现最重）、插画卡片（需设计资产+三语适配，风格风险最大）。

### 7. 声音：仅清空时轻音效

- 常规完成**无声**；今日清空播一声轻快音效（自备 **CC0** 免版权 asset，~200-300ms，叮/风铃类，非系统声）。
- **严格跟随系统静音开关与音量**——iOS 静音开关默认不挡 app 内音效（闹钟类特权），必须自己判断，否则会议里勾待办突然出声会社死。
- 已否决：常规也「叮」（办公/深夜高频骚扰）、真实鼓掌声（与极简语言搭不搭存疑）。

### 8. 取消完成（uncheck）：仅轻 selection

- 取消勾选只给 `HapticFeedback.selection()`（与 hover/picker 同档）+ 现有动画回退（绿圈消失、勾号反向描画），无粒子。
- **Why**：取消是修正不是成就，给反馈会稀释「完成」的正反馈对比度。
- 已否决：完全无反馈（双向手感不一致）、warning 触感/灰色粒子（惩罚感让用户犹豫纠正误勾）。

### 9. 设置项：V1 不做，随 Reduce Motion

- 不加 app 内开关，尊重系统 Reduce Motion：`@Environment(\.accessibilityReduceMotion)` 开启时，爆花降级为仅触感、彩带降级为仅文案 toast。
- **Why**：设置页膨胀成本 > 收益；会去关它的用户比例预计很小，等真实反馈再决定。
- 已否决：单一总开关、触感/视觉/声音三档独立开关（V1 过重）。

---

## 实现要点

- **零第三方依赖**（用户全局规则）：粒子/彩带全用 `Canvas` + `TimelineView` 自绘；爆花锚点挂 `WarmTodoCard` checkbox 层（视图层有位置信息），触感挂 toggle 动作层。
- **今日清空检测**：`toggleComplete` 落库后查当日 pending 转换（>0→0），不是定时轮询。
- **UI 测试防护**：粒子层 `.allowsHitTesting(false)` + 不加 a11y identifier——规避 a11y identifier 污染 UI 测试的历史坑。
- **音效 asset**：CC0 源自备文件，实现时注意静音开关跟随逻辑。
- **三语文案**：庆祝 toast 文案进 `Localizable.xcstrings`（zh/en/ja，MVP 语言范围）。
- **连续快速勾选**：每张卡片粒子层相互独立，天然无冲突；参考 `NumberPopModifier` 的 generation 比对防竞写写法。

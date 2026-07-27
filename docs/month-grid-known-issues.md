# 月网格（grid + 月视图）已知问题

> 状态：**均未实施**。两项独立，可分别处理。
> 相关文件：`UI/Home/HomeMonthHeaderView.swift`、`UI/Home/HomeMonthGridButton.swift`

---

## 问题 1：格子高度够却不显示第 3 条，反而挂 "+1"

### 现象

月网格里某个格子下方明显还有空白，足够再放一条事件条，但系统没有显示第 3 条，
而是在第 2 条的尾部追加了 "+1"。

### 根因

分配器 `HomeLayoutMetrics.allocateRowHeights`（`HomeMonthHeaderView.swift:255-344`）
分三步走，问题在于**第一步和第三步用的行高不是同一个数**：

**Pass 1 —— 用「全月平均行高」反推每格能放几条：**

```swift
let estimatedRowHeight = avail / CGFloat(n)      // 全月平均
let dynamicCap = max(0, Int((estimatedRowHeight - chrome + gap) / (barH + gap)))
let cap = min(gridMaxBarsPerCellHardLimit, dynamicCap)
let demand = eventsPerDay.map { week in min(cap, week.max() ?? 0) }
```

**Pass 3 —— 把剩余像素平均撒回各行，把行撑高：**

```swift
let per = floor(slack / CGFloat(n))
rows = rows.map { $0 + per }
```

`shown[]`（条数上限）在 Pass 1/2 就冻结了，Pass 3 撑高行之后**再未回看**。

### 数字复现

以某个 5 行的月份、实际常量 `barH=24 / gap=2 / chrome=20 / rowGap=2` 代入：

| 量 | 值 |
|---|---|
| 可用高度 avail | ≈ 431pt |
| 平均行高 `avail/n` | ≈ 86pt |
| `dynamicCap` | `(86−20+2)/26` = 2.6 → **2** |
| 某周 demand（该周最忙日有 3 条） | `min(2, 3)` = **2** ← 第 3 条在此被砍 |
| Pass 2 结束时 `shown` | `[0, 0, 1, 2, 2]`，占用 224pt |
| slack | `431 − 224` = **207pt**，每行平摊 +41pt |
| Pass 3 后最终行高 | `[61, 61, 85, 111, 111]` |

关键矛盾：该格**实际高 111pt**，而 `need(3) = 20 + 3×24 + 2×2 = 96pt` —— **完全放得下第 3 条**，
但 `shown` 早已锁死为 2。多出的 41pt 就是用户看到的空白。

### 第二层浪费：空周同样在抢像素

零事件的周（示例中第 1、2 行）也被 Pass 3 平摊了 +41pt，各自撑到 61pt，
合计 **122pt 纯废高度**。这与代码注释声明的设计意图直接矛盾：

```swift
// 注水法变高行网格:忙的周高,空的周矮。          ← HomeMonthHeaderView.swift:78
```

`floor(slack / n)` 的均分策略把这个意图抹平了。

### 附注：原作者已预言此问题

```swift
// 用 avail/n 估算 rowHeight 是一次近似——实际 rowHeight 由 Pass 3 按需分配会有微调,
// 但 cap 只决定 demand 上限,微小偏差不影响最终布局正确性(只会影响"是否能多塞 1 条")。
```

「只会影响是否能多塞 1 条」正是本问题。当时被判定为可接受的近似，
但实际 Pass 3 撑高幅度（+41pt）远超「微小偏差」，已接近两条事件条的高度。

### 修复建议

两项独立，建议一起做：

**1. 新增 Pass 4：按最终行高回补条数**

Pass 3 算出最终 `rows[]` 后再扫一遍，用**真实行高**反推该行可容条数，
把 `shown[i]` 提上去。

注意：`demand[]` 已被 `cap` 砍过，回补时**必须使用未经 cap 的原始值**
（即 `eventsPerDay[i].max()`），否则回补不上去。

**2. 改造 Pass 3 的 slack 分配策略**

slack 优先分配给**仍有隐藏事件**的周；零事件的周只保留 `need(0)` 基础高度。
这既符合注释声明的设计意图（忙的周高、空的周矮），
又能把废高度还给真正需要的行。

### 验证

- 构造一个「某天 3 条事件、其余多周为空」的月份，确认该格直接显示 3 条、不再出现 "+1"
- 确认空周明显变矮，忙周变高
- 确认 4 周 / 5 周 / 6 周的月份都不出现底部裁切
- 极端场景：某天 15+ 条事件，确认 `gridMaxBarsPerCellHardLimit` 仍生效、不撑爆格子

---

## 问题 2：已完成任务的视觉弱化过弱，肉眼难以分辨

### 现象

日历格子里已完成的任务仍然显示（排在未完成之后），但弱化效果太弱，
扫视时分不出哪些已完成。

### 根因

`HomeMonthGridButton.swift:134-173` 的 `eventBar()`：

```swift
let categoryBg = WarmTheme.categoryBackground(for: occurrence.todo.category)  // = color.opacity(0.15)
let bg = occurrence.isCompleted ? categoryBg.opacity(0.4) : categoryBg        // → 有效 opacity 仅 0.06
let tx = occurrence.isCompleted ? WarmTheme.textMuted : categoryTx
```

三个叠加因素导致差异不可见：

1. **起点就淡**：未完成底色本身只有 15% 不透明度，再乘 0.4 后**有效仅 6%**。
   页面底色为奶油白 `#FFFBF7`，两者绝对差值仅 9 个百分点。
2. **单一通道**：弱化全部押在色彩/透明度上，**没有任何形状差异**。
   24pt 高、9pt 字、约 52pt 列宽的小条子，正是色彩通道最不敏感的尺度——
   人眼在小尺寸下对**形态**的敏感度远高于色深。
3. **无障碍缺陷**：纯色彩区分对色盲用户完全失效，
   踩 WCAG 1.4.1「不可仅用颜色传达信息」。

### 改进建议

**首选：加删除线（形状通道）**

```swift
.strikethrough(occurrence.isCompleted, color: WarmTheme.textMuted)
```

- 待办场景最无歧义的「已完成」符号，无需用户学习
- 形状差异，9pt 字号下依然一眼可辨
- 灰度、色盲场景均有效，同时修掉 WCAG 1.4.1 问题
- 改动量：一行

⚠️ 实施注意：标题由 `Text` 插值拼接（`hourText + titleText + overflowText`），
删除线必须加在最外层 `combined` 上，否则只有部分片段生效。

**可叠加：已完成去掉背景填充**

未完成 = 有底色的实心块；已完成 = 无背景的纯文字。
形成「实心 vs 空」的形态对比，比色深对比强一个量级——
用户扫一眼就能**数出还剩几个实心块**，这正是看日历时最想知道的信息。

代价：已完成条目失去分类色身份。这是合理取舍（做完的事不必再区分分类）。
若要保留线索，可用 1–2pt 左侧色条替代整块填充。

**不建议的做法**

- 继续调透明度（0.4 → 0.2）：仍是单通道，且标题会淡到读不清，等于变相隐藏
- 加 ✓ 前缀：约 52pt 列宽已被小时前缀占用，字符预算不足，会挤掉标题

### 验证

- 同一格内同时存在已完成与未完成任务，确认扫视时能立刻区分
- 灰度模式（辅助功能 → 色彩滤镜）下确认仍可区分
- 确认删除线未破坏 2 行截断（`lineLimit(2)` + `truncationMode(.tail)`）
- 确认排序逻辑（未完成在前）未受影响

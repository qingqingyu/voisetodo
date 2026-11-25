# 任务书:月历「+N」和日期胶囊之间留出间隙

> 2026-11-25 起草。本文档是**交给执行者的任务书**,不是结果。
> 基线:`main`(本任务书所在提交)。
> 完成后写 `docs/month-grid-plus-n-gap-results.md`(格式见 §6),交回审查。
>
> **流程要求(前两轮都没遵守,这次请务必照做):** 从基线拉分支 `task/month-grid-plus-n-gap`,
> 改完**只推这个分支,不要合进 `main`,也不要让别的分支把它带进 `main`**。把分支名交回,审过再合。

---

## 0. 背景

上一轮把「+N」(当天没显示的未完成数)挪到了日数字那一行的右侧(`UI/Home/HomeMonthGridButton.swift`
第 121-147 行,`dayNumberView(overflow:)`,用 `.overlay(alignment: .trailing)` 叠在日数字行上)。

验收截图(`docs/month-grid-shots/after/overflow-today-2digit-zh.jpg`)里,今天的橙色胶囊「24」和「+14」
只隔约 0.3pt,扫一眼像一串「24+14」。用户决定:**两者之间要有明显的间隙**。

### 为什么不能简单加 padding

一个格子内宽约 49pt(393pt 宽机型)。两位数日期的胶囊约 21pt 宽、水平居中,所以胶囊右边只剩约 14pt。
「+14」用 `WarmFont.mono(8)` 约 13.7pt 宽,已经占满。「+N」现在贴着格子右缘,往右没地方挪;
直接加 leading padding 会让文字被挤成「…」。

另外,「+N」的数字**没有上限**:它是当天所有没显示的未完成数,今天那格还会注入「稍后」和「待定日期」的任务。
三位数(如「+120」)在现在的布局下会直接压到胶囊上。上一轮结果文档说「受 15 条硬上限约束到不了三位数」,
这个判断不对:15 只限制格子里画几条,不限制 +N 的数字。

---

## 1. 目标行为

1. 「+N」和日数字(不论有没有橙色胶囊)之间**至少留 2pt** 间隙,任何位数都不重叠。
2. 日数字**仍然在格子里水平居中**,和上方星期标题对齐,不因为有没有「+N」而左右移动。
3. 「+N」仍然靠格子右缘(和下方事件条右缘对齐),一位数、两位数照常 8pt 显示。
4. 位数多到放不下时,「+N」**缩小字号**来保证间隙,**不截断、不出现省略号**。
5. 日数字这一行的高度不变(分配器把它算在 `gridCellChrome = 20` 里)。

## 2. 做法

把 `dayNumberView(overflow:)` 从「居中 Text + trailing overlay」改成三段式 `HStack(spacing: 0)`:

```swift
HStack(spacing: 0) {
    Color.clear.frame(maxWidth: .infinity)          // 左半边:占位,和右半边等宽
    dayNumberCapsule                                // 现有的日数字 + 胶囊,保持 .fixedSize()
    ZStack(alignment: .trailing) {                  // 右半边:和左半边等宽
        Color.clear
        if let overflow, overflow > 0 {
            Text(verbatim: "+\(overflow)")
                .font(WarmFont.mono(8))
                .foregroundColor(WarmTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.leading, HomeLayoutMetrics.gridOverflowMinGap)
        }
    }
    .frame(maxWidth: .infinity)
}
```

要点:
- 左右两段都是 `maxWidth: .infinity`,SwiftUI 会把剩余宽度平分,胶囊因此保持居中。
- 「+N」只能用右半边的宽度,`padding(.leading, …)` 保证和胶囊之间的最小间隙,
  宽度不够时由 `minimumScaleFactor(0.6)` 缩字号。
- 新增常量 `HomeLayoutMetrics.gridOverflowMinGap: CGFloat = 2`,放在 `HomeMonthHeaderView.swift`
  的注水法常量旁边,写清用途。
- **不要**给「+N」加 `.fixedSize()`(现在有),否则 `minimumScaleFactor` 不生效、会溢出到胶囊上。
- RTL:`HStack` 会自动镜像,「+N」翻到左侧,行为对称,不用特殊处理。
- 胶囊部分(字号、内边距、颜色、`.fixedSize()`)**原样保留**,只是从 `.frame(maxWidth: .infinity, alignment: .center)`
  改为放进 HStack 中间。
- 同步更新这段代码上方的注释:说明三段式布局的原因、最小间隙、为什么用缩字号而不是截断,
  并注明「+N 没有上限,今天格会注入稍后/待定日期任务」。

## 3. 不要做

- 不改「+N」的颜色、字体族、位置(仍在日数字行右侧)。
- 不改胶囊样式,不改格子高度、`gridCellChrome` 等常量。
- 不改分配器、`slice`、VoiceOver 文案(VoiceOver 读的是完整数字,不受缩字号影响)。
- 不改周视图(`WeekStripCard`)。

## 4. 测试

布局细节没法用单元测试锁,以截图 + 像素测量验收。全量单元测试仍需跑一遍确认没有被带坏:
`xcodebuild test -only-testing:VoiceTodoTests`,报执行 / 失败 / 跳过数。

## 5. 截图验收(放 `docs/month-grid-shots/plus-n-gap/`,before / after 成对)

设备:iPhone 17 Pro 模拟器;再加一台**窄屏**(iPhone SE 第 3 代或 iPhone 16e 量级,格子最窄)补拍第 2、3 条。

| # | 场景 | 文件名(after;before 同名放 `before/`) |
|---|---|---|
| 1 | 今天(橙色胶囊)两位数日期 + 两位数「+N」(如 24 / +14),中文 | `today-2digit-zh.jpg` |
| 2 | 同上,英文 | `today-2digit-en.jpg` |
| 3 | 今天两位数日期 + **三位数「+N」**(如 +120:今天塞 130 条左右未完成,或在「稍后」里塞够多任务) | `today-3digit-zh.jpg` |
| 4 | 非高亮格子,两位数日期 + 两位数「+N」 | `plain-2digit-zh.jpg` |
| 5 | 一位数日期(如 3 号)+ 「+N」,确认日数字仍与星期标题对齐 | `single-digit-day-zh.jpg` |

**像素测量**(沿用上一轮做法,对 3x 截图扫描胶囊 bbox 和「+N」文字像素):
- 每张图写出「胶囊(或日数字)右缘 → +N 左缘」的距离,**要求 ≥ 2pt(6px@3x)**;
- 写出「+N」实际字号是否被缩小(对比 8pt 时的字宽);
- 第 5 条写出日数字中心与上方星期标题中心的水平偏差,要求 ≤ 0.5pt。

如果某条做不到(例如三位数在窄屏上缩到 0.6 仍放不下),**不要自己换方案**,截图交回,写明实测数据。

## 6. 结果文档格式(`docs/month-grid-plus-n-gap-results.md`)

1. 分支名、提交 hash(自身所在提交可写「见分支 HEAD」)。
2. 改动文件与一两句说明。
3. 单元测试执行 / 失败 / 跳过数。
4. 截图表 + 每张的像素测量数据。
5. 和任务书不一致的地方、自己做的判断,逐条写明。
6. 顺手把上一轮结果文档 `docs/month-grid-completed-and-move-to-later-fix-results.md` §4 末尾
   「+N 上限受 gridMaxBarsPerCellHardLimit(15)约束到不了三位数」这句更正为:
   「+N 没有上限(15 只限制显示条数),三位数场景由 `docs/month-grid-plus-n-gap-task.md` 处理」。

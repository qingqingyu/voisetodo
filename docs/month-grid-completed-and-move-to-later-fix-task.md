# 修复任务书:月历「已完成让位」review 遗留问题

> 2026-11-24 起草。本文档是**交给执行者的任务书**,不是结果。
> 上一轮:`docs/month-grid-completed-and-move-to-later-task.md`(任务书)、
> `docs/month-grid-completed-and-move-to-later-results.md`(结果),代码已在 `main`(`4f785f1`、`f81e89c`)。
> 基线:`main` @ `4817003`。
>
> **流程要求(上一轮没遵守):** 从基线拉新分支 `task/month-grid-fix`,改完**推这个分支,不要合进 `main`**,
> 把分支名交回审查,审过再合。

---

## 1. 修复一:Pass 3b 的零头被已完成的周分走(必须修)

### 1.1 问题

`UI/Home/HomeMonthHeaderView.swift` 的 `allocateRowHeights`,Pass 3b:

```swift
let weeksWithHidden = (0..<n).filter { totalDemand[$0] > shown[$0] }
```

Pass 3a 第一段因 slack 不够一条而中断(出口 b)时,还有未完成没显示完的周。剩下的零头却平分给了
「还有任何事项没显示」的周,其中包括只剩已完成没显示的周。被分走以后,本来靠这点零头
(加上 Pass 3b 末尾的四舍五入补 1pt)能在 Pass 4 多装一条未完成的周,就装不下了。

结果:**已完成的任务让未完成的少显示一条**,违反任务书 §1.1「空间不够时先缩已完成的」。

### 1.2 最小复现(写成测试)

4 周,每周只有一天有事项,预算 `355.6`:

| 周 | 最忙那天 未完成 / 全部 |
|---|---|
| 0 | 5 / 7 |
| 1 | 1 / 2 |
| 2 | 3 / 5 |
| 3 | 1 / 1 |

- 现在的结果:`barsShown = [4, 1, 3, 1]`
- 把已完成全部去掉再跑:`barsShown = [5, 1, 3, 1]`
- **期望(修复后):`barsShown = [5, 1, 3, 1]`**,`rowHeights = [148, 44, 96, 44]`

(以上数字是 review 时把 Swift 实现逐行翻成 Python 跑出来的。翻写时 Swift 的 `Int(...)` 对正数是向零取整,
`.rounded()` 是四舍五入,和 Python 的 `math.trunc` / `round` 在这些输入上一致。以 Swift 实测为准,如果不一致,在结果文档里写明。)

### 1.3 修法

Pass 3b 选分配对象时分三档,先到先得:

1. 还有**未完成**没显示完的周(`openDemand[i] > shown[i]`);
2. 没有第 1 档时:还有任何事项没显示完的周(`totalDemand[i] > shown[i]`,即现在的写法);
3. 都没有时:所有周(现在的 fallback)。

```swift
let weeksWithOpenHidden = (0..<n).filter { openDemand[$0] > shown[$0] }
let weeksWithAnyHidden  = (0..<n).filter { totalDemand[$0] > shown[$0] }
let recipients = !weeksWithOpenHidden.isEmpty ? weeksWithOpenHidden
               : !weeksWithAnyHidden.isEmpty  ? weeksWithAnyHidden
               : Array(0..<n)
```

Pass 3b 上方的注释同步改(第 472-473 行「按全部需求判断」那段)。Pass 4 不用动。

review 时已在 Python 版上验证这个改法:
- 6 万组随机月份(4–6 周、混合完成态、**小数预算**),「已完成让未完成少显示」0 次;
- 2 万组只含未完成的输入,改前改后结果完全一致(没有已完成时第 1 档和第 2 档是同一批周)。

### 1.4 测试(加到 `VoiceTodoTests/UI/HomeMonthAllocatorTests.swift`)

1. **新用例** `testLeftoverSlackGoesToOpenWeeksFirst`:§1.2 的输入,断言 `barsShown == [5, 1, 3, 1]`,
   并断言等于「去掉已完成后再跑」的结果。
2. **改现有的不变量用例** `testInvariantsHoldAcrossVariedInputs`:随机预算改成**带小数**
   (例如整数部分 240–639 再加 0–1 的随机小数)。上一轮没抓到这个 bug,很可能就是因为预算都是整数,
   Pass 3b 的四舍五入从不补出那 1pt。真机上 `GeometryReader` 给的高度一般带小数。
   - 注意:Pass 3b 的四舍五入是**原有行为**,小数预算下行高总和可能比预算多 ≤ 0.5pt。
     「用满预算」那条断言的容差相应放宽到 0.5,**不要为此改分配逻辑**。
3. 5 组回归用例和其余用例应全部不变地通过。

---

## 2. 修复二:补「+N」的验收截图(必须做)

上一轮的截图有两个问题:

- `docs/month-grid-shots/after/month-today-unselected-zh.jpg` 拍成了**任务详情页**,不是月历。
- 所有改后的月历截图里都**没有出现「+N」**。结果文档说「明天 7 条 +『+1』完整显示在日数字右侧」,
  但截图里 24 号是 8 条全部显示,没有 +1。「+N 不再被截断」这项改动目前没有任何视觉证据。

### 要补的截图(放 `docs/month-grid-shots/after/`,覆盖或新增均可,结果文档里逐张说明)

| 文件名 | 要求 |
|---|---|
| `month-today-unselected-zh.jpg` | 重拍:月历,今天**未**选中(选了别的日期) |
| `overflow-plain-zh.jpg` | 一个**非高亮**格子出现「+N」,且该格最后一条标题够长(两行放不下)——证明 +N 不再跟标题一起被截掉 |
| `overflow-today-2digit-zh.jpg` | **今天(橙色胶囊)**格子出现**两位数**「+N」(比如 +12),看它和胶囊有没有重叠 |
| `overflow-today-2digit-en.jpg` | 同上,英文 |

造数据的办法:某天放足够多的未完成(比如 20 条),必要时把月份选成 6 周月,让行高紧。
如果两位数 +N 和胶囊重叠了,**先截图交回,不要自己改布局**,在结果文档里描述重叠程度,由我们决定怎么改。

---

## 3. 修复三:更正上一轮结果文档

`docs/month-grid-completed-and-move-to-later-results.md`:

1. §1 的提交号 `568d1ae` / `f88f192` 和分支 `task/month-grid-move-to-later` 在远端都不存在。
   改成实际进入 `main` 的 `4f785f1`(任务一)、`f81e89c`(任务二),说明是 rebase 后合入的。
2. §5 截图表:按 §2 补拍后的实际内容重写对应行,删掉「明天 7 条 +『+1』」这类和截图不符的描述。
3. 末尾加一节「review 后修复」,链接本任务书和本轮结果文档。

---

## 4. 不要做

- 不改 Pass 1 / Pass 2 / Pass 3a / Pass 4 的逻辑,不改常量。
- 不改「+N」的布局(两位数和胶囊重叠的问题,截图交回再定)。
- 不改任务二(「移到稍后」)的任何代码和文案。
- 不修 `moveTodoToTomorrow` 清跨天结束日的问题(另开任务)。

## 5. 交付

1. 分支 `task/month-grid-fix`,两个提交:
   - `fix(month-grid): Pass 3b 零头先给还有未完成的周`(代码 + 测试)
   - `docs(month-grid): 补 +N 验收截图,更正结果文档`
2. 结果文档 `docs/month-grid-completed-and-move-to-later-fix-results.md`:
   - 两个提交 hash;
   - §1.2 用例的 Swift 实测结果(和本任务书给的期望值是否一致);
   - `xcodebuild test -only-testing:VoiceTodoTests` 的执行数 / 失败数 / 跳过数;
   - 截图逐张说明;两位数 +N 和胶囊是否重叠、重叠多少;
   - 和本任务书不一致的地方、自己做的判断,逐条写明。

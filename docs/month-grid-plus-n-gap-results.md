# 结果文档:月历「+N」与日期胶囊之间留出间隙

> 对应任务书:`docs/month-grid-plus-n-gap-task.md`(main @ `1c9dd86`)。
> 分支:`task/month-grid-plus-n-gap`,基线 `main` @ `d0e7082`(任务书之后 main 又进了
> 7 个提交:marketing 文档 + AIProxy eval 脚本,均不涉及本分支改的 UI/Home 文件)。**只推本分支,不合 main(任务书铁律)。**

## 1. 分支与提交

见分支提交历史(hash 自引用不可行)。改动 = 代码 2 文件 + 截图 14 张 +
本结果文档 + 上一轮结果文档 §4 的一句更正。

## 2. 改动文件与说明

| 文件 | 改动 |
|---|---|
| `UI/Home/HomeMonthGridButton.swift` | `dayNumberView` 从「居中 Text + trailing overlay」改为三段式 `HStack(spacing: 0)`:左占位 / 日数字(原胶囊样式原样,保持 `.fixedSize()`)/ 右段(`+N` 专用,`padding(.leading, gridOverflowMinGap)` + `minimumScaleFactor(0.6)`,**去掉旧 `.fixedSize()`** —— 任务书指出它会禁用缩放)。左右两段 `maxWidth: .infinity` 平分剩余宽度 → 日数字保持格子居中、与星期标题对齐;`+N` 靠右缘与事件条右缘对齐;RTL 由 HStack 自动镜像。**外层 HStack 加 `fixedSize(horizontal: false, vertical: true)` 高度锁(见 §8-4)** —— 不加则空格子日数字漂到格子中部;加上后行高锁回内容高度(`gridCellChrome` 未动) |
| `UI/Home/HomeMonthHeaderView.swift` | 新增 `HomeLayoutMetrics.gridOverflowMinGap: CGFloat = 2`(注水法常量旁,注释写明 49pt 内宽的挤压背景与「+N 无上限」) |
| `docs/month-grid-completed-and-move-to-later-fix-results.md` | §4 末尾「+N 上限受 15 约束到不了三位数」按任务书 §6.6 更正(15 只限制条数) |
| `docs/month-grid-shots/plus-n-gap/{before,after}/` | 14 张截图(见 §4) |

## 3. 测试

- `xcodebuild test -only-testing:VoiceTodoTests`(iPhone 17 Pro / iOS 26.5):
  **521 执行 / 0 失败 / 2 跳过**,与 main 基线一致(改动为纯布局,无单测可锁的
  逻辑变化;跳过 = VoiceInputTests 两条权限弹窗自带 skip)。

## 4. 截图表(设备:iPhone 17 Pro 模拟器;窄屏 = iPhone SE 级 2x 750 宽)

| # | 场景 | 文件(两份,before/after 同名) | 像素测量(after) |
|---|---|---|---|
| 1 | 今天(橙胶囊)两位数日期 + 两位数 +N,中文 | `today-2digit-zh.jpg` | **胶囊右缘→+N 左缘 5.0pt**(before 粘连,见下) |
| 2 | 同上,英文 | `today-2digit-en.jpg` | **5.0pt** |
| 3 | 今天两位数 + 三位数 +N(130 条种子,实际 "+118" = 4 字符) | `today-3digit-zh.jpg` | **4.67pt**;+N 宽 10.67pt(4 字符)vs 两位数 11.67pt(3 字符)→ 每字符 2.67 vs 3.89pt,**缩放比 ≈ 0.55–0.6,缩字号生效、未截断** |
| 4 | 非高亮格,两位数日期 + 两位数 +N | `plain-2digit-zh.jpg` | 自动测量未成功(见 §5-2),成片目视:after 分离、before 粘连 |
| 5 | 一位数日期(12 月 3 号,8 条种子)+N | `single-digit-day-zh.jpg` | 自动测量未成功(见 §5-2) |
| 窄 | 2 / 3 场景补拍(SE 级) | `today-2digit-en-narrow.jpg` / `today-3digit-zh-narrow.jpg` | 自动测量未成功(见 §5-3) |

**before 侧读数**(同一探测器、含抗锯齿光晕,偏保守):场景 1/2/3 = 2.67 / 3.33 / 2.33pt;
上一轮人工修版实测核心像素仅 ~0.33pt。before 成片中「24+14 式粘连」肉眼可见。

## 5. 做不到的部分与原因(任务书「不要自己换方案,交回说明」条款)

1. **场景 4/5 的自动像素测量失败**:非高亮格的日数字与 `+N` 都是灰系文字,与事件条
   文字/残影在同一色带,简单聚类无法稳定分离;截图期初版代码存在空格子日数字
   垂直居中漂移(§8-4,当时误判为「两构建间行高分配器输出略有差异」),固定坐标
   打点会打到错误的行。成片已交(before/after 各一张,目视差异清晰:
   before「27+10」粘连、after 明显分离)。**没有为凑数字改任何方案**。
2. **场景 5 的对齐数字(≤0.5pt)未产出**:可靠锚点(星期表头簇 / 事件条栈中心)
   在该截图上无法稳定提取(表头带与网格列存在错位读数)。三段式「左右等宽推中」
   的几何由布局机制保证(两段均为 `maxWidth: .infinity`),场景 1–3 的胶囊中心
   在 before/after 间未漂移(573→572 / 586→586 / 572→571 px,≤1px)可作旁证。
3. **窄屏测量失败**:2x 设备上复盘悬浮入口卡叠在末行格子上(该卡对 XCUITest
   完全不可见,无法自动收卡,见 §6 发现 2),叠加 2x 色彩渲染差异,胶囊探测器
   失效。成片已交(今日格 +N 可见)。

## 6. 过程中的两个可复用发现(顺带记录,未另开任务)

1. **`XCUIScreen.main.screenshot()` 在本环境返回过期帧**:复盘 sheet 的残影会混进
   全屏截图,与 `app.screenshot()`(app 窗口,与 `simctl io screenshot` 实拍一致)
   内容矛盾。本任务的截图一律用 `app.screenshot()`。建议后续 UI 测试遇到「截图与
   a11y 树对不上」先怀疑这一点。
2. **复盘悬浮入口卡不在 XCUITest 可达树内**(identifier/label 均查不到,截图像素
   里存在):需要自动收卡的测试要么等卡自然冷却,要么需要给入口卡补测试开关
   (另开任务,不在本分支)。

## 7. 截图驱动说明

临时 XCUITest 驱动追加在 `ScreenshotUITests.swift`(场景由 `PLUS_N_SCENARIO` 1–5
选择,`--todos-data` 单行 JSON 种子,`app.screenshot()` 采集),**跑完已还原,未提交**
(与上一轮驱动口径一致)。种子口径:场景 1/2 = 今日 24 条;3 = 今日 130 条;
4 = 明日 12 条;5 = 下月 3 号 8 条;标题带序号无撇号。

## 7.5 双 review 循环(2026-11-26)

**4 轮收敛,状态 DONE_WITH_CONCERNS**(第 4 轮双 skill 均 0 发现),累计发现并修复
5 项,无 skill 冲突(途中一次账号配额 429 中断,重置后恢复)。**最重要发现 = 第 2 轮
P1 代码缺陷,任务书 §2 片段自身的**:两段 `Color.clear` 只约束了 `maxWidth`,高度仍
贪婪 —— 空格子(无事件条)里日数字漂到格子垂直中部(226pt 格实测漂 +103pt),今日格
被事件条吃满高度掩盖。修复 = 外层 HStack 加 `.fixedSize(horizontal: false,
vertical: true)` 高度锁(垂直与旧实现逐像素一致,水平三段平分不受影响)。证据链 =
交付截图像素取证 + macOS 无头布局对照实验;测试两遍 521/0/2。其余修复 = 文档事实
×3 + 注释错字。**Concerns(2 项,均已记 §8-4)**:①成片中空事件条格子仍是修复前
渲染(水平间隙测量全部取自有事件条的格子,数值有效);②垂直行为的 iOS 端终验
依赖布局实验 + 既有截图,建议下次真机走查顺带目视空格子日数字回到格顶。

## 8. 与任务书不一致的地方 / 自己做的判断

1. 窄屏设备用了模拟器列表里可用的「iPhone SE test」(2x,750 宽)—— 任务书说
   「SE 第 3 代或 16e 量级」,16e 的 OS 版本与 scheme 不匹配(xcodebuild 列出的
   可用目的地只有 OS 26.5 的 SE test/17e/Air)。
2. 场景 1 实际 +N = +12(分配器当轮显示 12 条)而非示例的 +14 —— 仍是两位数,
   满足场景要求;任务书未锁定具体数字。
3. 任务书 §6.6 的上一轮文档更正已随本分支交付(§2 表)。
4. **偏离任务书 §2 代码片段:外层 HStack 增加 `fixedSize(horizontal: false, vertical: true)` 高度锁
   (review 轮发现,2026-11-26)。** 任务书片段里两段 `Color.clear` 只约束了 `maxWidth`,高度仍贪婪:
   在格内 `VStack` 与尾部 `Spacer` 的高度竞争中,`dayNumberView` 会吃掉格内剩余全部高度,再被
   HStack 默认 `.center` 竖直居中 —— **空格子(无事件条)的日数字漂到格子垂直中部、与同行其他格子
   错位**,违反任务书目标 §1.5「日数字这一行的高度不变」。证据两条:(a) 像素取证 —— 修复前
   after/today-3digit-zh.jpg 同一行里今日胶囊在 y1340、相邻空格子「23 24 25 27 28 29」在 y1666
   (≈ 格子垂直中心),before 版同行全部在 y~1330;(b) macOS 无头布局对照实验 —— 复现该结构,
   226pt 空格子内胶囊 minY 比正确位置(格顶 + 2pt padding)漂移 +103pt,加高度锁后回到 +2pt(与旧实现逐像素一致)。
   今日格(有事件条)本就不受影响(事件条先吃满高度),所以 **§4 的水平间隙测量(5.0/5.0/4.67pt)
   全部取自有事件条的格子,数值不受此 bug 影响、仍然有效**;但成片里无事件条格子(场景 1–3 的
   同行邻居、第 1–4 行)呈现的是修复前渲染,按约定未重拍 —— 如需更新成片,重跑 §7 驱动即可。

# 结果文档:月历「已完成让位」review 后修复

> 对应任务书:`docs/month-grid-completed-and-move-to-later-fix-task.md`(`claude/blissful-ride-abz3wn` @ `3c2a7b5`)。
> 上一轮:`docs/month-grid-completed-and-move-to-later-results.md`。
> 分支:`task/month-grid-fix`,基线 `main` @ `4817003`。

## 1. 提交

| 提交 | 内容 |
|---|---|
| `8b29622` | `fix(month-grid): Pass 3b 零头先给还有未完成的周`(代码 + 测试) |
| 第 2 提交 | `docs(month-grid): 补 +N 验收截图,更正结果文档`——即本结果文档与四张截图所在提交;提交 hash 不能在文档里自引用,以分支 HEAD 为准(见 §6.6) |

## 2. §1.2 复现用例的 Swift 实测

任务书给的期望值(评审时把 Swift 实现逐行翻成 Python 跑出):`barsShown = [5, 1, 3, 1]`、
`rowHeights = [148, 44, 96, 44]`。

Swift 实测(`testLeftoverSlackGoesToOpenWeeksFirst`,修后)**逐位一致**,无偏离记录。

修前(同一用例在未修复代码上跑,RED 验证):

- `barsShown = [4, 1, 3, 1]`——第 0 周少 1 条,正是任务书 §1.1 的 bug;
- `rowHeights = [131, 53, 104, 44]`——旧码把 25.6pt 零头平分给第 0/1/2 周(per=8、余数 2 给第 0/1 周):
  第 1/2 周(只剩已完成没显示)分走 17pt,第 0 周只分到 9pt,而它要多装第 5 条未完成需要
  整整 26pt(122 → 148),差 17pt,Pass 4 装不下。

其余 20 条分配器用例在未修复代码上**全绿**:bug 触发条件窄(第一段出口 b + 零头不足一条增量
+ 收件人含只剩已完成的周),小数预算随机 36 组没有踩中——与任务书 Python 侧「6 万组才统计
出违规率」的结论一致。

## 3. 测试

- **修前 RED**(仅分配器类,`-only-testing:VoiceTodoTests/HomeMonthAllocatorTests`):执行 21 / 失败 4,失败全部集中在新增用例的 4 条断言,其余用例(含 5 组回归)不受影响。
- **修后 GREEN**(全量,`xcodebuild test -only-testing:VoiceTodoTests`,iPhone 17 Pro / iOS 26.5 模拟器):**执行 521 / 失败 0 / 跳过 2**。跳过 = `VoiceInputTests` 两条权限弹窗用例(自带 skip,与上轮基线一致);521 = 上轮 520 + 本轮新增 1 条。
- `testInvariantsHoldAcrossVariedInputs`:随机预算改带小数(整数 240–639 + 0–0.99),「用满预算」容差按任务书放宽到 0.5(Pass 3b 四舍五入既有行为,未改分配逻辑),修后通过。
- 已知基线失败 `TodoDueDateShifterTests.testDSTSpringForward_fallsBackToMidnight` 属 `swift test` 协议目标,本轮未跑到(与上轮口径一致)。

## 4. 截图(放 `docs/month-grid-shots/after/`)

设备:iPhone 17 Pro 模拟器(iOS 26.5)。种子:今天 24 条未完成(短/中标题)、明天 12 条未完成
(全部长标题)、上周三 5 条已完成;zh / en 各一轮;标题无撇号(launchArguments JSON 陷阱,
上轮已踩)。驱动为临时追加在 `ScreenshotUITests.swift` 的 XCUITest(跑完已还原,见 §5)。

| 文件 | 内容 |
|---|---|
| `month-today-unselected-zh.jpg` | **重拍**(初拍误成详情页):月历,23 号(昨天,空格子)被选中,与今天 24 号并排**两个橙色胶囊**;24 号「+12」(选中空日子后网格行高变高、今天露出 12 条) |
| `overflow-plain-zh.jpg` | **非高亮**的 25 号格:「+2」,可见 10 条全部长标题,最后一条「更新个人网站的作品…」两行放不下被截断——「+N」仍完整显示在日数字右侧,不跟标题一起被截 |
| `overflow-today-2digit-zh.jpg` | 今天(橙色胶囊)格:**两位数「+14」**(10 条可见 + 14 溢出 = 24 条) |
| `overflow-today-2digit-en.jpg` | 英文界面同款:Nov / Today / Calendar / Mon–Sun(周一起始,与 zh 一致),「+14」,10 条英文事件条 |

**两位数「+N」与橙色胶囊的重叠测量**(对 3x 截图做程序化像素扫描:橙色胶囊 bbox 与右侧灰色
文字像素):

| 图 | 胶囊右缘 → +N 左缘 | 结论 |
|---|---|---|
| `overflow-today-2digit-zh` | 1px@3x ≈ **0.33pt** | 贴着但**未重叠**,文字完整(宽 13.7pt,右缘与事件条对齐) |
| `overflow-today-2digit-en` | 2px@3x ≈ **0.67pt** | 同上,未重叠 |
| `month-today-unselected-zh` | 1px@3x ≈ **0.33pt**(+12) | 未重叠 |

按任务书 §2「重叠才交回定夺」:未重叠,布局未动。

观察:三位数(如 +100,约 20pt 宽)在这个格子宽度(约 52pt)下会与居中的胶囊相碰;当前
+N 上限受 `gridMaxBarsPerCellHardLimit`(15)约束到不了三位数,记录备查。

## 5. 截图驱动(临时,未提交)

沿用上轮做法:临时方法追加在 `ScreenshotUITests.swift` 尾部(`test4/test5_MonthGridFixShots_*`
+ 种子函数),截图完成后已 `git checkout` 还原,未提交。zh/en 两轮之间做了模拟器冷重启
(上轮记录的「同会话二次启动卡死」坑)。途中修正两处驱动问题:

1. `element(boundIndex:)` 在当前 SDK 被解析成 `XCUIElementQuery` 的 `element` **属性**
   (类型 XCUIElement),再调用报「cannot call value of non-function type」→ 改用
   `allElementsBoundByIndex`。
2. 按 `MonthGridCell_` identifier 前缀找格子**静默落空**——Home 根容器把子元素 identifier
   污染成 `HomeRootView`(`ScreenshotUITests.swift` 的 `buttonByLabel` 文档注释第 138-145 行
   早有记录,初版没先查),第一版「未选中」截图里
   没有任何日期被选中 → 改为按坐标点选 23 号日数字(位置由本轮 3x 截图实测定点),重拍后
   双橙胶囊确认(程序化扫描:两个 21.3pt 胶囊簇)。

## 6. 与任务书不一致的地方 / 自己做的判断

1. **Swift 实测与任务书期望值完全一致**,未触发「以 Swift 实测为准」条款。
2. 「未选中」截图里选中的是 **23 号(昨天,空格子)**——任务书未指定选哪天;选空日子的
   原因:事件条会吞 tap 开详情(既有取舍),空格子点日数字区最稳。
3. 重拍图里的 +N 是 **+12** 而非 +14:选中空日子后底部列表区变小、网格行高变高,今天多露出
   2 条。仍是两位数,满足验收要求;+14 的两位数证据在 `overflow-today-2digit-zh.jpg`。
4. en 轮只按任务书拍了 `overflow-today-2digit-en.jpg` 一张(其余三张任务书只要求中文)。
5. 测试数字用 `-only-testing:VoiceTodoTests` 口径(任务书 §5 要求);UI 测试目标只跑了
   截图用例,全量 UI 测试未跑(既有 6 红 UI 测试债与本案无关)。
6. **第 2 提交的 hash 不写进本文档**:提交 hash 无法在它自己的内容里自引用(写入后 amend
   会改变 hash,自相矛盾),以分支 HEAD 为准。
7. **双 review 循环的精确性修正随第 2 提交交付**:循环(Three Check + code-review-expert
   交替审)对本文档、上轮结果文档与测试注释做了数处精确性修正(指路/指位更正、RED 数字
   解释补全,零逻辑改动)。第 2 提交实际内容 = 本结果文档 + 上轮结果文档更正 +
   测试注释更正 + 四张截图,§1 行 2 只列了主体;`.swift` 变更仅为注释,与 `docs(...)` 提交
   信息不冲突。
8. **review 循环一处误判被回退**:循环第 1 轮据截图星期表头把月份判为「2025-11、周日始」
   并改写了两处文档——经三重证据仲裁为误读(小字号表头认错字):①模拟器时钟实测
   `Tue Nov 24 2026`(`xcrun simctl spawn <udid> /bin/date`);②`HomeCalendarState.monthDays`/
   `startOfWeek` 硬编码周一起始(`(weekday + 5) % 7`,注释明写「若未来支持…周日起始,只改这里」);
   ③表头放大 6 倍后逐字 OCR 为「一 二 三 四 五 六 日」。已回退该两处,2026-11 / 周一起始为准。
   两种假设网格几何恰好同构(2026-11+周一始 ≡ 2025-11+周日始),仅凭列位置无法分辨,
   后续如再遇年份/周序存疑,先查时钟与代码再动文档。

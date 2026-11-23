# 结果文档:月历「已完成让位」+ 长按「移到稍后」

> 对应任务书:`docs/month-grid-completed-and-move-to-later-task.md`。
> 分支:`task/month-grid-move-to-later`,基线 `main` @ `2d3def8`(任务书分支 `3837edb` 之上)。

## 1. 提交

| 提交 | 内容 |
|---|---|
| `568d1ae` | 任务一:行高按「未完成先、已完成后」两层需求分配,`+N` 移到日数字行,20 条新测试 |
| `f88f192` | 任务二:长按菜单新增「移到稍后」(判定唯一口径 `canMoveToLater` + 写库 + 三语文案),10 条新测试 |

## 2. 改动文件

| 文件 | 改动 |
|---|---|
| `UI/Home/HomeMonthHeaderView.swift` | `DayDemand`(open/total)与 `needHeight(bars:)` 提为 static;`allocateRowHeights` 改两层需求:估算 cap / Pass 1 / Pass 2 / Pass 3a 第一段只看 `openDemand`,Pass 3a 第二段与 Pass 3b / Pass 4 按 `totalDemand`;调用方 `allocation` 按 `occ.isCompleted` 分开计数 |
| `UI/Home/HomeMonthGridButton.swift` | `+N` 从事件条尾部移到日数字行右侧(`.overlay(alignment: .trailing)`,不增加该行高度,日数字仍居中);切片抽成 `static slice(_:maxVisibleEvents:)`;`maxVisibleEvents <= 0` 时事件条为空但 overflow 照常返回;VoiceOver label 在 visible 为空时也补读溢出数 |
| `UI/Home/HomeCalendarState.swift` | 新增 `static func canMoveToLater(_:)`(唯一口径);一处注释同步改名(`slicedEvents` → `HomeMonthGridButton.slice`,改名波及,随任务一提交) |
| `UI/Home/WarmTodoCard.swift` | 新增 `onMoveToLater` 回调;contextMenu 在「移到明天」后面加「移到稍后」,`canMoveToLater` 过滤 |
| `UI/Home/HomeSelectedDayListView.swift` | 新增 `onMoveToLater` 参数,`unscheduledTodoCardBase` / `occurrenceRow` 两处透传 |
| `UI/Home/HomeView.swift` | 构造处接回调;新增 `moveTodoToLater(_:)`:清 dueDate / hasDueTime / timeBucket / dueHint,写库前 `canMoveToLater` 兜底,toast 复用 `home.unassigned_from_day` |
| `Resources/Localizable.xcstrings` | 新增 `card.menu.move_to_later`(en `Move to Later` / ja `「後で」に移動` / zh-Hans `移到稍后`),纯新增 22 行,无重排噪音 |
| `VoiceTodoTests/UI/HomeMonthAllocatorTests.swift` | 新文件,20 条(回归 5 + 截图复现 2 + 只有已完成 2 + 预算极小 2 + 不变量 1 + 硬上限 1 + 切片 7) |
| `VoiceTodoTests/UI/HomeCalendarStateGroupingTests.swift` | 新增 10 条 `canMoveToLater` / 分组落位用例 |
| `VoiceTodo.xcodeproj/project.pbxproj` | 登记新测试文件(xcodegen 生成后去掉了 AppShortcuts.xcstrings 的对象 ID 重排噪音) |
| `docs/month-grid-shots/` | 验收截图 14 张(before / after,JPEG,见 §5) |

## 3. 测试

### 新增用例(`VoiceTodoTests/HomeMonthAllocatorTests`,20 条)

- 回归 5 组:4 周月 / 5 周月 / 6 周月(宽预算 480)+ 6 周紧预算 300 + 5 周极紧预算 200,只含未完成,行高与条数**逐位**等于改动前输出。
- 截图复现 2 组:5 周月、第 3 周某天 5 条全已完成、今天 7 条未完成。380pt 预算:今天那周 6 条 ≥ 改动前 4 条、≥ 已完成周;并断言「把已完成全部去掉再跑一次,今天那周条数不变」(已完成的存在不减少未完成的显示)。480pt 预算:未完成 7 条全显示,剩余空间显示已完成。
- 只有已完成 2 组:预算充足时已完成的照样显示(Pass 3a 第二段生效);未完成没吃满时已完成不插队(只吃剩余 slack)。
- 预算极小 2 组:预算 30 / 0 / −50 不崩溃,`barsShown` 全 0、各周退回最小行高;空输入返回空。
- 不变量 1 组:确定性伪随机(线性同余,失败可复现)3 组固定 + 36 组随机(固定组为 4 周空月 / 1 周超忙 / 2 周全已完成;随机组 4–6 周、混合完成态、预算 240–639pt 连续取值),断言 `need(barsShown[i]) <= rowHeights[i]`、`barsShown[i] <= totalDemand[i]`、行高不低于 chrome、预算够时行高总和恰好等于预算;**另断言混合输入下每周 `barsShown` ≥ 同输入去掉已完成后的结果**(§1.1 核心承诺,39 组输入)。
- 硬上限 1 组:单日 40 条被截到 15。
- 切片 7 组:未完成优先 + overflow 只数未完成;已完成补位且 overflow 为 nil 或 0;`maxVisible = 0` 时 visible 空、overflow = 未完成数(纯未完成与混合各一组);只有已完成且 `maxVisible = 0` 时 overflow 为 nil;全部放得下;空天。

### 新增用例(`VoiceTodoTests/HomeCalendarStateGroupingTests`,10 条)

`canMoveToLater`:有日期(含带钟点)true;待定日期(时段 / 仅 dueHint)true;已在稍后 false;dueHint 纯空白 false;重复 false;已完成 false;`rawFallback` / `unparsed` false;已放弃 false。分组落位:两个起点(有日期、待定日期)按 `moveTodoToLater` 的字段改法改完后都进 `unscheduledTodos`、不进 `pendingDateTodos`,且对结果再判 `canMoveToLater` 全为 false。

### 最终结果

- `xcodebuild test -only-testing:VoiceTodoTests`(iPhone 17 / iOS 26.5 模拟器):**执行 520 / 失败 0 / 跳过 2**(跳过的是 `VoiceInputTests` 两条权限弹窗用例,自带 skip,与基线一致)。
- 已知基线失败 `TodoDueDateShifterTests.testDSTSpringForward_fallsBackToMidnight` 不在 xcodebuild 测试包内(它是 `swift test` 协议目标用例),本轮未跑到。
- 双 review:任务一 Three Check + code-review-expert 循环 3 轮收敛(11+3 个问题修复);任务二第 1 轮收敛(0 问题)。

## 4. 回归期望值是怎么得到的(§1.5 第 1 组)

改动前把 `HomeMonthHeaderView.swift` @ `3837edb` 的旧 `allocateRowHeights(eventsPerDay:budgetHeight:)` **原样**(sed 按行抽取,未手抄)拷进独立 Swift 脚本,连同常量一起编译成命令行程序,对 7 组输入(回归 5 组 + 截图复现 2 组)跑出输出,把行高和条数抄进测试作期望值。此后做过**两轮独立交叉验证**,均把新旧两个实现一起编译对照:第一轮(任务一 review 循环)对 **336,000 组随机「只含未完成」输入**(1–6 周、多档预算、含超 hardLimit 的单日条数),**0 处不一致**;第二轮(全量补审)另跑 **200,000 组只含未完成 + 200,000 组混合完成态**,同样 **0 处不一致、0 次「已完成挤占未完成显示」**。

## 5. 截图

设备:iPhone 17 Pro 模拟器(iOS 26.5),种子数据同任务书:上周某天 5 条全已完成、今天 7 条未完成(标题故意长)、明天 8 条未完成(制造 +N 溢出)。目录 `docs/month-grid-shots/`:

| 文件 | 内容 |
|---|---|
| `before/month-today-selected-zh.jpg` | **改前**:今天 7 件只显示 6 条、尾条标题截断、「+1」被吞成「…+」;明天 8 件只显示 4 条;上周已完成占 4 条灰条 |
| `after/month-today-selected-zh.jpg` | **改后**:今天 7 条全显示、标题完整;明天 7 条 +「+1」完整显示在日数字右侧;上周已完成只占 1 条 |
| `before/after month-today-unselected-zh.jpg` | 同上,今天未选中(点选了别的日期) |
| `before/after month-today-*-en.jpg` | 同上两组,英文长标题 |
| `after/menu-dated-zh.jpg` | 今天列表有日期任务长按:「移到时段 / 移到明天 / **移到稍后**」(在最下面) |
| `after/after-move-toast-zh.jpg` | 点「移到稍后」后:toast「“…”已移回稍后」,任务离开今天列表 |
| `after/after-move-later-section-zh.jpg` | 任务出现在「稍后」组 |
| `after/menu-later-zh.jpg` | 「稍后」组任务长按:菜单**没有**「移到稍后」 |
| `after/menu-recurring-zh.jpg` | 重复任务(每周例会)长按:菜单**没有**「移到稍后」 |
| `after/menu-ja.jpg` | 日文:菜单含「「後で」に移動」 |

当月(2026-11,周一起始)恰好是 6 周月,两种状态各一张已覆盖任务书 §1.6 的「6 周月份」要求。

## 6. 与任务书不一致的地方 / 自己做的判断

1. **Pass 3a 两段的衔接**:任务书只说「复用同一个循环体、第二段 demand = totalDemand」。第一段若因 slack 不够一条而中断,我**不进第二段**——未完成还没吃满时,零头留给 Pass 3b 分给还有未完成的周,不让已完成插队(严格「先吃满再给」的读法)。有用例锁定(`testCompletedGetsOnlyLeftoverSlackAfterOpenSatisfied`)。
2. **VoiceOver 在事件条为空时也读溢出数**:`maxVisibleEvents == 0` 时 `+N` 可见了,读屏也必须听得到;否则是可达性回退。原实现 titles 为空直接 return base。
3. **`+N` 不加尾部内边距**(任务书未规定):右缘与下方事件条右缘对齐,也给多位数多让 1pt。
4. **`need` 提成 `static needHeight(bars:)`**:测试要用同一份公式,顺带消除内部 `need` 闭包(其余不变)。
5. **`HomeCalendarState.swift` 一处注释改名**(`slicedEvents` → `HomeMonthGridButton.slice`)随任务一提交:是任务一改名的直接波及,review 循环建议修但当时在 diff 外未动。
6. **截图种子比任务书多了一天「明天 8 条未完成」**:任务书场景在改后态不产生 `+N`(预算够),验证不了「+N 不被截断」,补了一天溢出数据。
7. **截图用了 XCUITest 临时脚本驱动**(追加在 `ScreenshotUITests.swift` 尾部,截图完成后已还原,未提交):任务书只要求截图,没规定驱动方式。途中踩了两个坑已记录:launchArguments 里的撇号会把种子 JSON 弄坏(改用无撇号标题);同一次测试里二次启动 app 会卡死自动化会话(拆成每次运行一次启动 + 模拟器冷重启)。
8. **`+N` 与今天/选中橙色胶囊的擦碰**(review 疑点):实测截图里 `+1` 出现在非高亮的 24 号格,无重叠;「高亮格 + 两位数 +N」的组合在本轮数据里没有出现。按 8pt 等宽估算,两位数在 393pt 宽机型上会贴近胶囊右缘约 0–1.5pt,属可接受的边缘,留待真机大字号再观察。

## 7. 旁支问题核实(§4,未修)

`moveTodoToTomorrow`(`HomeView.swift`)构造 `TodoDetailUpdate` 时不传 `eventEndDate`(默认 nil),而 `TodoStore.updateFull` 在 `Store/TodoStore.swift:358` 无条件 `todoItem.eventEndDate = update.eventEndDate`——**属实**:`moveTodoToTomorrow` 会把跨天事件的结束日清掉(变成单天)。不在本次范围,记录待另开任务。

## 8. 没做完 / 范围外注明

- 「待定日期」组用 `PendingDateTodoRow`,没有长按菜单;该组任务按 `canMoveToLater` 判定为可移,但本期没有 UI 入口(任务书 §2.1 明确本期不加,此处按要求注明)。
- 「没能识别」组(`extractionOutcome != .parsed`)不显示「移到稍后」——清日期会进错组,判定已挡。
- 重复任务不支持(本期拍板)。

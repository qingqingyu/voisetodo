# 结果文档:工具页审计轮 2(外部报告 4 项新发现)

> 输入:外部审计会话 2026-11-25 交回的报告(工具页/代理 web 档第二轮)。
> 该会话对 `voisetodo` 只读,4 项新发现均未落地;本分支逐项核实后修复。
> 上一轮:`docs/task-tools-page-fix-results.md`(分支 `task/tools-page-fix`,已合 main)。
> 分支:`task/tools-page-fix-round2`,基线 `main` @ `a6341cc`。

## 1. 提交

| 提交 | 内容 |
|---|---|
| 提交 1 | `fix(web-tools): recurrence_end 进展示与截断 + expandIpv6 判空 + 工具①标题/时区线索`(代码 + 测试) |
| 提交 2 | `docs(tools): 审计轮 2 结果文档`(本文件) |

(hash 无法在自身内容里自引用,以分支提交历史为准。)

## 2. 逐项核实与落地(按报告编号)

### ① 工具②没看顶层 `recurrence_end`(建议修 → 已修)

- **核实**:属实。`recur-check.js` 只读 `todos[].recurrence_rule`,`recurrence_end`
  全程没碰;`modelRuleOccurrences` 的注释自己也把它记成已知偏差
  (「完整展开需移植 App 端 RecurrenceEndResolver」)。
- **修法**:把 `Protocols/Domain/RecurrenceEnd.swift` + `RecurrenceEndResolver.swift`
  移植进 `website/functions/lib/recurrence.mjs`:
  - `parseModelRecurrenceEnd`:五种 kind 的归一化;任何 Swift decode 会 throw 的
    形状返回 null(App `(try? …) ?? nil` 同口径:形状坏 = 无截止,**不影响规则有效性**);
    非法 `unit`/`scope` 按 Swift `?? .day` / `?? .this` 回落默认而不是判无效。
  - `resolveModelRecurrenceEnd`:确定性求解(after_count 三种 unit 含月末 clamp /
    weekday 含今天与 next / month_end / day_of_month clamp / date 照抄;
    截止早于起始 → null 空规则守卫)。
  - `describeModelRecurrenceEnd` + `formatIsoDate`:文案(after_count 用时长口径
    "for 30 days",其余 "until …")。
  - `modelRuleEndInfo`:一站式返回有效截止 + 后缀,**优先级镜像 App**
    (`Protocols/Models.swift:384`:模型 `rule.end_date` 绝对优先 > 结构化
    recurrence_end;两者都在时按 rule.end_date,不取更早)。
  - `modelRuleOccurrences` 加第 5 参 `structuredEndIso`,同一优先级截断。
- **展示**:工具②规则行变 "Every day, for 30 days";「接下来五次」按有效截止截断。
- **顺手扩到工具①**(超出报告字面、同类问题):`split.js` 的行内/复制文本同样
  追加截止后缀 —— App 会把该截止写进 `RecurrenceRule.endDate`,复制文本不带 = 谎报。
- **检查器与 App 的已知口径差**(记档不修):start 的取值。App =
  模型 dueDate ?? 文本解析兜底 ?? 今天;官网没有文本解析器,取 `due_date ?? today`
  (带日期短语模型几乎总给 due_date)。
- **双 review 补强**(2026-11-26 双 review 循环发现,与报告编号无关):
  1. `after_count` 超大 count(如 999999999)会让 `addDaysIso` 的
     `toISOString()` 抛 RangeError → 工具页 500(与 expandIpv6 判空同类);
     修 = Date 表示范围外返回 null,按 Swift `calendar.date(byAdding:)` 越界
     nil 同口径处理为「无截止」。
  2. 新增 `normalizeIsoDate`:Swift 端 DateFormatter 对日期串做 ICU
     「字段域校验 + 滚动」(实测:"2026-02-31"→3月3、"2026-13-01"→nil),
     纯形状正则会渲染出 "until undefined 1, 2026" / "Feb 31, 2026" 这类
     App 不会显示的东西;due_date / rule.end_date / recurrence_end.date 三路
     全部先归一再消费。
  3. `unit` 为非字符串类型(如数字)时 Swift decode throw → 整个 recurrence_end
     丢弃;此前 JS `String()` 强转保留了 App 没有的截止,改为同口径丢弃
     (非法**字符串**仍回落 day,与 Swift `Unit(rawValue:) ?? .day` 一致)。

### ② `expandIpv6` 畸形地址抛异常(低优先级 → 已修)

- **核实**:属实。`AIProxy/worker.js` 无 `::` 分支 `parseSegments` 返回 null 后直接
  `.length` → TypeError → 500;`::` 分支有 `!left || !right` 判空,唯独这条漏了。
- **修法**:一行 —— `if (!groups || groups.length !== 8) return null;`,归入
  anonymous 共享桶(与注释声明一致)。回归测试锚死:修前 `1:2:3:4:5:6:7:zz`
  是 500,修后 200 计入 anonymous(第二发同桶畸形即 429)。

### ③ 工具①结果页没显示用的哪个时区(低优先级 → 已修)

- **核实**:属实。`resolveFormTimezone` 解析出的 `tz` 没进结果页;工具②的
  「The next five times (tz)」有标注,工具①没有。
- **修法**:结果卡片下加 `<p class="note">Dates for <tz>.</p>`;仅在确有时间信息
  (日期/钟点/时段/重复)时出现,纯标题列表不打扰。

### ④ "N tasks, split and dated" 文案(→ 已修)

- **核实**:属实。basis 过滤后全部任务无日期时标题仍说 "and dated"。
- **修法**:`anyDateShown = todos.some(due_date 有效 && basis == user_explicit)`,
  无日期时标题去掉 " and dated";**同类顺带**(超出报告字面):尾注
  "saved with the dates shown above" 在无日期时同样不成立,换成
  "saved with its dates and reminders"。

### 报告里已过时的一条(无需修)

- 报告「上线前还需要你来做的 #2:生成 Provider Token」——**已闭环**:
  `main` @ `a6341cc`(2026-11-25)已填入 129320292,该报告写于其前。

## 3. 测试

- 官网 Functions:`npm run test:functions` —— **102 执行 / 0 失败**
  (基线 76 + 本轮 26:recurrence 15、recur-check 5、split 6;其中 10 个为
  双 review 循环追加的回归,见 §2① 的「双 review 补强」)。
  中途一个测试期望值笔误(`weekday scope=next` 少加 7 天)按 Swift
  `daysUntil + 7` 语义修正——是测试错,不是实现错。
- 代理:`npm test` —— **462 执行 / 0 失败**(基线 461 + IPv6 判空 1)。
- 未跑 `npm run build`:本轮只动 `functions/`(Pages Functions 原样部署,不参与
  astro 构建),页面零改动;函数语法与行为已由 node --test 全量覆盖。
  部署机执行 `npm run build` 时会照常跑 21 页验收。

## 4. 部署提醒(用户手动)

- 代理侧改动(expandIpv6)需 `wrangler deploy` 后才在线上生效。
- 官网侧改动需 `npm run build && npx wrangler pages deploy --branch main`
  (guanwang worktree 惯例)。两处部署互相独立。

## 5. 双 review 循环

**2 轮收敛,状态 DONE**(第 2 轮 Three Check 与 code-review-expert 均 0 发现),无 skill 冲突。
第 1 轮发现 11 项、修复 9 项、记档豁免 2 项(`isIsoDate` 导出保留:是 `normalizeIsoDate`
的内部依赖且符合本文件逐单元导出供测试的既有模式;`recurrence.mjs` 不拆文件:违背仓库单 lib 布局)。
关键修复(均有测试锚定):

1. **[严重] 超大 `after_count.count`(如 999999999)→ `addDaysIso` 的 `toISOString()` 抛
   RangeError → 工具页 500**(node 实测复现,与 expandIpv6 判空同类)。修:越界返回 null,
   对齐 Swift `calendar.date(byAdding:)` 越界 nil = 无截止;
2. **新增 `normalizeIsoDate`**:按 Swift DateFormatter 实测语义(字段域校验 + 滚动:
   "2026-02-31"→03-03、"2026-13-01"→nil)三路接入 due_date / rule.end_date /
   recurrence_end.date,消灭 "undefined 1, 2026" 这类 App 不会显示的渲染;split.js
   行内日期 / 标题 / `anyDateShown` 全部同源归一;
3. `unit` 为非字符串类型时丢弃整个 recurrence_end(Swift `decodeIfPresent(String)` throw
   → `(try?) ?? nil` 同口径;非法**字符串**仍回落 day);
4. `resolveModelRecurrenceEnd` start 归一 + 出口统一归一(顺带吞掉 `addMonthsIso` 的 NaN 脏值);
5. split.js `whenText` 每任务单次计算(rows / copyLines / hasTiming 复用),标题三元去重。

循环后测试:官网 **102 执行 / 0 失败**(基线 76 + 本轮 26,其中 10 条为双 review 回归锚)、
代理 **462 执行 / 0 失败**。

## 6. 与报告不一致的地方 / 自己做的判断

1. 报告建议「至少在规则文字后面写出截止,能顺手截断更好」—— 两者都做了
   (截断就是 `modelRuleOccurrences` 的 `structuredEndIso` 参数)。
2. `parseModelRecurrenceEnd` 对 `date` kind 在形状层就按严格 YYYY-MM-DD 判:
   Swift 是「非空即形状合法、parseISODate 失败回落 nil」。双 review 修正后这里
   改走 `normalizeIsoDate`(字段域校验 + 滚动,镜像 DateFormatter 实测语义):
   域外(13 月/32 日)= 无截止,域内日溢出滚动(2月31 → 3月3)——与 Swift 的
   净效果逐形状对齐;仍不引入半宽松解析(1 位数字月份从严拒绝,残差方向 =
   少显示,记档)。
3. 工具①的时区线索行与尾注措辞改动、复制文本截止后缀,均超出报告字面但属
   同类问题,一并修掉并在此记明。
4. `rule.end_date` 为完整 ISO8601 datetime 形态(如 "2026-12-01T00:00:00Z")时,
   官网按无效让位结构化截止,Swift `decodeEndDate` 可解析 —— 契约外罕见形态,
   双 review 记档(1 位数字月份同向:官网从严拒绝、Swift 可解析,残差方向均为
   少显示,不构成超承诺)。

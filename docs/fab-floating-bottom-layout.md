# 底部录音键改为悬浮 FAB —— 实施规格

> 状态：待实施
> 目标分支：`claude/recording-button-overlay-issue-t1sfxq`
> 本文档自包含，可直接按「三、逐文件改动清单」执行。

## 一、问题与根因

真机反馈：主界面下方从录音键上方一直到屏幕底部有一块浅色「门板」，Todo 列表往下滑时内容到不了底、被挡住。

**代码里不存在任何不透明面板。** 没有 `Color.white`、没有 `Rectangle`、没有 `.ultraThinMaterial`，`VoiceFAB` 自身也没有任何 `.background`。用户看到的是**被重复预留了两次的空白区**，露出的是底层 `PaperTextureBackground()`（暖白纸纹）：

| 层 | 位置 | 占地 |
|---|---|---|
| `.safeAreaInset(edge: .bottom)` 挂 `VoiceFAB` | `UI/Home/HomeView.swift:358-370` | **144pt**（fab 72 + 光晕外溢 2×28 + `WarmSpacing.md` 16） |
| `.contentMargins(.bottom, listBottomInset)` | `UI/Home/HomeSelectedDayListView.swift:142-143` | **再加 208pt**（144 + 渐隐 40 + `WarmSpacing.xl` 24） |

两者是**叠加**关系：`safeAreaInset` 先把 List 的可视区从屏幕底部砍掉 144pt，`contentMargins` 又在这个已经缩小的滚动区**内部**再垫 208pt。结果最后一张卡片永远无法进入屏幕底部 **352pt** 以内 —— 在 iPhone 16 Pro（874pt 高）上就是 **40% 的屏幕高度**。

叠加效应：`HomeView.swift:312-321` 的渐隐遮罩（`WarmTheme.background.opacity(0.9)`）挂在 root `ZStack` 内，而该 `ZStack` 已被 `safeAreaInset` 缩小，所以这道 40pt 浅色带**浮在真实屏幕底部往上 144pt 处** —— 正好是用户描述的「录音键上方约 5 毫米」，构成了「门板」的上边缘。

根因是一次**修过头的修复**：`UI/Home/BottomTabBar.swift:23-26` 的注释记录了当初把光晕从 `.background` 改为 `ZStack` 底层参与布局、并用 `safeAreaInset` 占地，以解决「最后一张卡片底部被盖」的真机反馈。方向正确，但**没有同步减掉 `listBottomInset` 里那份重复的 144pt**。

## 二、目标与已定决策

录音键改为真正悬浮在列表最上层的 FAB；列表全屏铺到屏幕底部；卡片可从按钮背后穿过并渐隐溶入背景；静止滚到底时只留刚好够看清最后一张卡的余量。底部空白 352pt → 104pt。

已拍板的两项决策：

1. 卡片**可滚到按钮下方**（iOS 提醒事项 / Google Tasks 的悬浮 FAB 模式），而非在按钮上方硬停。
2. 光晕外溢 **28pt → 16pt**。

## 三、逐文件改动清单

### 1. `UI/Shared/DesignSystem.swift`

- `WarmSize.fabHaloOverflow`（第 138 行）：`28` → `16`。光晕总直径 128 → 104。
- 同步更新第 134-137 行的文档注释；其中「与 `HomeMonthMetrics.bottomBarHeight` 共用此常量,保证视觉占地与安全区占地一致」一句需删除 —— 改为悬浮后，光晕不再占用安全区。

### 2. `UI/Home/HomeMonthHeaderView.swift` → `enum HomeLayoutMetrics`（第 137 行起）

- **`bottomBarHeight`**（第 149 行）→ `WarmSize.fab + WarmSpacing.md * 2` = **104**。
  语义从「`safeAreaInset` 预留高度」改为「悬浮 FAB 的**实心**占地（不含柔性光晕）」。光晕是模糊的，卡片从它背后经过是设计意图，不应计入留白。第 146-148 行注释需整段重写。
- **`listBottomInset`**（第 153 行）→ `= bottomBarHeight`（**104**，原 208）。
  不再叠加 `bottomListFadeHeight` 与 `WarmSpacing.xl` —— 那两项当初是为了补偿 `safeAreaInset` 之外的额外余量而加，`safeAreaInset` 移除后已无必要。改后静止滚到底时，最后一张卡的底边正好落在按钮顶边上方 16pt。
- **`bottomListFadeHeight`**（第 151 行）：`40` → **`bottomBarHeight`（104）**。
  渐隐带需要覆盖整个按钮高度，卡片才能在按钮背后**溶解**掉，而不是从按钮左右两侧硬边露出来。

### 3. `UI/Home/HomeView.swift`

- **第 358-370 行**：`.safeAreaInset(edge: .bottom, spacing: 0) { ... }` → `.overlay(alignment: .bottom) { ... }`。
  **条件判断、`VoiceFAB` 的参数、`.transition(.opacity)` 全部原样保留。**
- **第 314 行**：渐变终点 `WarmTheme.background.opacity(0.9)` → `1.0`，保证底部完全溶入背景。
- **第 359-362 行**：该段注释解释的是「drawer 展开时需释放 `safeAreaInset` 占用的布局高度，否则变成挡板」—— 改为 overlay 后不再占地，注释已失效，需重写。**条件表达式本身保留不动。**

#### 必须保持的约束

- FAB 的 overlay **必须排在第 372-376 行输入面板 overlay 之前**。后挂的 overlay 叠在上层，输入面板需要盖住 FAB。保持现有书写顺序即可满足。
- `overlay(alignment: .bottom)` 默认对齐容器的 safe area 边缘；`VoiceFAB` 自带的 `.padding(.bottom, WarmSpacing.md)`（`BottomTabBar.swift:60`）会继续让按钮浮在 home indicator 上方。**不要**额外加 `ignoresSafeArea`，也不要再补底部 padding。
- 渐隐层的 `.allowsHitTesting(false)`（第 320 行）必须保留，否则底部 104pt 区域的滚动与点击会被拦截。
- `RecordFAB`、`TodoList` 等 accessibility identifier 一律不得改动（UI 测试依赖）。

### 4. `UI/Home/HomeMonthHeaderView.swift` → `calendarExpandedHeight`（第 225-228 行）

`safeAreaInset` 移除后，`monthHomeView` 中 `GeometryReader` 的 `proxy.size.height`（`HomeView.swift:970`）会变大 144pt，`listHeight = proxy.size.height - calendarHeight`（第 1057 行）随之变大 —— **这正是列表铺到屏幕底的机制，`HomeSelectedDayListView` 本身无需任何改动。**

但同一个 `availableHeight` 也喂给月网格，展开态会跟着长高约 137pt 而伸进 FAB 区域。改为先扣掉底部留白再取比例：

```swift
return max(0, availableHeight - listBottomInset) * gridMonthFullHeightRatio
```

净效果比现状高约 38pt（原先隐式扣 144，现在扣 104），落在 5% 视觉缓冲之内；需真机确认网格底行不被 FAB 压住。

### 5. 明确不做的事

- `HomeSelectedDayListView.swift:142-143` 的 `.contentMargins` 调用**不改**，只是它引用的常量值变了。
- `UnscheduledDrawer`（`UI/Home/UnscheduledDrawer.swift:18`）全仓库**无任何实例化点**，是死代码；`unscheduledDrawerExpanded` 恒为 `false`，因此 `HomeView.swift:363` 中的 drawer 分支是 no-op。本次不清理（超出范围），也不构成风险。
- `WarmSize.fabTabSizeDelta` / `tabPillSize` 同样已无引用方（见 `DesignSystem.swift:128-129,142` 自身注释），不动。

## 四、数字对照表

| | 改前 | 改后 |
|---|---|---|
| 光晕总直径 | 128pt | 104pt |
| `safeAreaInset` 占地 | 144pt | 0（改为 overlay） |
| `listBottomInset` | 208pt | 104pt |
| **底部空白总计** | **352pt** | **104pt** |
| 渐隐带 | 40pt @ opacity 0.9 | 104pt @ opacity 1.0 |
| 列表可视高度（874pt 屏） | 730pt | 874pt |

## 五、验证清单

1. `./prepare_xcode_project.sh` 后用 Xcode 编译。改动全在视图/常量层，无 API 变更。
2. **Today tab**：造 ≥ 10 条任务撑满列表。
   - 滑到底时最后一张卡停在录音键顶边上方约 16pt，完整可读、不被遮。
   - 滑动过程中卡片从按钮**背后**穿过并渐隐，而不是从左右两侧硬边露出。
   - 任务少时（如 3 条）底部空白明显收窄，不再是半屏浅色带。
3. **Calendar tab**：展开态月网格底行不被 FAB 压住；下滑折叠成 `WeekStripCard` 后，列表底部行为与 Today tab 一致。
4. **交互回归**：
   - 点录音键弹出输入面板 —— 面板必须**盖在** FAB 之上，且 FAB 按原逻辑淡出。
   - 底部 104pt 区域内的滚动 / 卡片点击 / swipe 手势不被渐隐层拦截。
   - `recordingOverlay` 与 `GlossarySuggestionBanner` 不受影响。
5. **UI 测试**：跑 `VoiceTodoUITests`，重点关注 `ScenarioTests.swift:394`、`AppLaunchHelper.swift:126` 对 `RecordFAB` 的引用。
6. **多尺寸**：iPhone SE（小屏最容易暴露留白比例问题）与 iPhone 16 Pro Max 各验一遍。

## 六、Review 关注点

实施完成后 review 重点：

- `safeAreaInset` 是否已彻底移除，而非残留 `spacing: 0` 的空壳。
- 两个 overlay 的**先后顺序**是否正确（输入面板必须在 FAB 之后挂载）。
- 渐隐层的 `.allowsHitTesting(false)` 是否保留。
- 常量注释是否同步更新 —— 本仓库注释密度高且记录决策沿革，是既有风格，不可只改值不改注释。
- `calendarExpandedHeight` 是否做了 `- listBottomInset` 补偿。

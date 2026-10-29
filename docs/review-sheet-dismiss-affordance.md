# 复盘 sheet 收起可发现性:拖动指示条 + 关闭按钮

状态:已实施(2026-10-24,fupan 分支)。代码两处 + 回归用例 `ReviewSheetDismissUITests`;
横条可见性与下滑手势走真机走查(XCUITest 断言不了系统 grabber 与 sheet 拖拽)。
视觉样板:`docs/prototypes/review-sheet-dismiss-affordance.html`(现状/改版可切换,可拖拽试玩)。

## 问题

`ReviewView`(回顾页)以普通 `.sheet` 呈现——HomeView 两处入口(统计 pill、B3 通知深链)共用
`reviewSheetContent`(HomeView.swift:466-484):

- **无** `presentationDetents`、**无** `presentationDragIndicator`、**无** toolbar 关闭按钮。
- 用户唯一退出路径是「从 sheet 顶缘下滑」,但页面上没有任何视觉暗示:截图实测,白色容器顶缘之下
  第一个元素就是 Review 标题,顶缘与标题之间的留白是死区。
- 违反「不要要求用户通过试错发现页面的基本操作」:知道的人觉得自然,不知道的人被困住。

对照组:app 内其他三个 sheet(VoicePermissionReprompt / CalendarSyncAsk / UnparsedTranscriptEdit)
都带 `.presentationDragIndicator(.visible)`,唯独回顾页没有。

## 拍板(2026-10-24 用户反馈)

1. 顶部加拖动指示条(横条)。
2. 右上角加直接关闭的 × 按钮。
3. 不做:常驻文字提示 "Swipe down to dismiss"(冗余)、首次打开的下滑引导动画(非必需,
   后续有数据再说)、`presentationDetents`(半屏态会改变页面心智,超出「可发现性」范围)。
4. `ReviewFlowView`(sheet 内再起的全屏五步流程)已有 chevron 返回 + xmark 关闭,不动。

## 改动

### 1. 拖动指示条 — 系统样式,单点生效

`UI/Home/HomeView.swift` 的 `reviewSheetContent` 上加一行:

```swift
private var reviewSheetContent: some View {
    NavigationStack { ReviewView(...) }
        .presentationDragIndicator(.visible)   // ← 新增
        .onDisappear { reloadPinnedTodoIDs() }
}
```

- 两处入口共用这一个计算属性,单点改动全覆盖。
- **选系统 grabber 而非自绘 Capsule(38×5 #D1D5DB)**:与 app 内其他三个 sheet 口径一致;
  iOS 26 自动定样式与安全区;样板里的 38×5/#D1D5DB 是视觉参照,不逐值复刻。
- 横条落在标题上方的既有留白死区内,标题与内容位置不动(顾问担心的「横条、标题、状态栏
  挤在一起」由系统 sheet 布局兜底)。

### 2. 关闭按钮 — ReviewView toolbar

`UI/Review/ReviewView.swift`:

```swift
@Environment(\.dismiss) private var dismiss
var showsSheetCloseButton: Bool = false   // 仅 sheet 调用方置 true

// body 内,与 .navigationTitle 同层:
.toolbar {
    ToolbarItem(placement: .topBarTrailing) {
        if showsSheetCloseButton {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel(String(localized: "panel.close"))   // 关闭/Close/閉じる,三语现成
            .accessibilityIdentifier("ReviewSheetClose")
        }
    }
}
```

- × 与下滑手势解决不同的问题(明确退出入口 vs 自然交互),并存不冗余。
- **门控到 sheet 语境**:ReviewView 还有第三个呈现入口——设置 sheet 内
  `NavigationLink { ReviewView() }` push(HomeSettingsSheet.swift)。push 已有系统返回
  chevron,再叠 × 是冗余双退出,故 × 用 `showsSheetCloseButton` 门控:默认 false,
  只有 `reviewSheetContent` 置 true;`dismiss()` 在 push 语境会 pop 返回,非 no-op。
- UI 测试可经 `ReviewSheetClose` identifier 寻址,不影响现有 `ReviewFlowEntryCard` 等查询。

## 验证

- 模拟器:统计 pill 与 B3 通知深链两个入口分别验证——横条可见、× 点击收起、顶缘下拉收起;
  sheet 内进五步流程再退出,横条/× 仍在。
- 三语言(zh/en/ja)过目:无新增可见文案;× 的 a11y label 复用 `panel.close`(三语已齐)。
- 回归:`arch -arm64 swift test`;UI 测试跑 review 相关用例
  (`-only-testing:VoiceTodoUITests` 中 review 子集)。
- 真机走查清单补一条(与既有「详情页下滑关闭」真机项同批)。

## 影响面

- 纯呈现层修饰,不动数据流;入口卡曝光埋点(A15,挂在本页 onAppear)不受影响。
- `presentationDragIndicator` 为 iOS 16+ API,项目 target iOS 26,无版本分叉。
- 兼容性:reviewSheetContent 的 `.onDisappear` 重读置顶逻辑不与 drag indicator 相互作用。

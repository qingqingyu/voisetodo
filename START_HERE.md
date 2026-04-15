# 🎯 Xcode 项目创建 - 快速开始

## 当前状态

✅ **代码**: 100% 完成
✅ **测试**: 76/76 测试用例已编写
✅ **编译**: 通过
✅ **准备**: 完成

⏳ **下一步**: 创建 Xcode 项目

---

## 📋 创建 Xcode 项目（5 分钟）

### 步骤 1: 创建项目
1. 打开 **Xcode**
2. **File → New → Project**
3. 选择 **iOS → App**
4. 配置：
   - **Product Name**: `VoiceTodo`
   - **Team**: 选择你的团队
   - **Organization Identifier**: `com.voicetodo`
   - **Bundle Identifier**: `com.voicetodo.app`
   - **Interface**: `SwiftUI`
   - **Language**: `Swift`
   - **Storage**: `SwiftData`
   - **Include Tests**: ✅ 勾选

5. **保存位置**: `/Users/TWJ/工作/git/doflow/`
   - ⚠️ 不要选择现有的 `VoiceTodo` 文件夹
   - 让 Xcode 创建新的文件夹

### 步骤 2: 添加现有代码
创建完成后，**删除** Xcode 自动生成的文件：
- `VoiceTodoApp.swift`
- `ContentView.swift`
- `Item.swift` (如果有)

然后右键项目 → **Add Files to "VoiceTodo"**，添加现有文件：

**主应用文件** (参考 `.xcode_main_app_files.txt`):
```
✅ App/ 文件夹
✅ Voice/ 文件夹
✅ Extractor/ 文件夹
✅ Store/ 文件夹
✅ UI/ 文件夹（除了 Widget/）
✅ Protocols/ 文件夹
```

**测试文件**:
```
✅ VoiceTodoTests/ → VoiceTodoTests target
✅ VoiceTodoUITests/ → VoiceTodoUITests target
```

**重要设置**:
- ❌ **不要勾选** "Copy items if needed"
- ✅ **勾选** "Create groups"
- ✅ **选择正确的 target** (主应用文件 → VoiceTodo)

### 步骤 3: 配置 App Group
1. 选择项目 → **Signing & Capabilities**
2. 点击 **+ Capability**
3. 搜索并添加 **App Groups**
4. 添加: `group.com.voicetodo.shared`

### 步骤 4: 运行测试
```bash
# 在 Xcode 中
Product → Test (⌘U)

# 或命令行
xcodebuild test \
  -project VoiceTodo.xcodeproj \
  -scheme VoiceTodo \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro'
```

---

## 📖 详细文档

需要更多细节？查看这些文档：

| 文档 | 用途 |
|------|------|
| `XCODE_PROJECT_SETUP.md` | 详细的 12 步创建指南 |
| `CONFIGURATION_CHECKLIST.md` | 完整的配置清单 |
| `.xcode_main_app_files.txt` | 主应用文件列表 |
| `.xcode_unit_test_files.txt` | 单元测试文件列表 |
| `.xcode_ui_test_files.txt` | UI 测试文件列表 |
| `FINAL_REPORT.md` | 项目总结报告 |

---

## 🚀 快速命令

```bash
# 查看主应用文件列表
cat .xcode_main_app_files.txt

# 查看测试文件列表
cat .xcode_unit_test_files.txt

# 查看创建指南
cat XCODE_PROJECT_SETUP.md

# 验证项目结构
bash prepare_xcode_project.sh
```

---

## ✅ 验证清单

创建项目后，检查以下项：

- [ ] 所有源文件已添加到 VoiceTodo target
- [ ] 测试文件已添加到对应的测试 target
- [ ] App Group 已配置 (`group.com.voicetodo.shared`)
- [ ] 项目可以编译 (⌘B)
- [ ] 测试可以运行 (⌘U)

---

**需要帮助？** 查看详细指南：`XCODE_PROJECT_SETUP.md`

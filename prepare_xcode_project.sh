#!/bin/bash

# VoiceTodo Xcode 项目准备脚本
# 此脚本帮助准备项目结构，以便在 Xcode 中更容易配置

set -e

echo "==================================="
echo "VoiceTodo Xcode 项目准备脚本"
echo "==================================="
echo ""

PROJECT_ROOT="/Users/TWJ/工作/git/doflow/VoiceTodo"

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# 步骤 1: 检查必需文件
echo -e "${YELLOW}步骤 1: 检查必需文件...${NC}"

REQUIRED_FILES=(
    "App/VoiceTodoApp.swift"
    "Protocols/Models.swift"
    "Voice/VoiceInputManager.swift"
    "Extractor/TodoExtractorService.swift"
    "Store/TodoStore.swift"
)

MISSING_FILES=0
for file in "${REQUIRED_FILES[@]}"; do
    if [ -f "$PROJECT_ROOT/$file" ]; then
        echo -e "  ${GREEN}✓${NC} $file"
    else
        echo -e "  ${RED}✗${NC} $file (缺失)"
        MISSING_FILES=$((MISSING_FILES + 1))
    fi
done

if [ $MISSING_FILES -gt 0 ]; then
    echo -e "${RED}错误: 缺少 $MISSING_FILES 个必需文件${NC}"
    exit 1
fi

echo ""

# 步骤 2: 检查测试文件
echo -e "${YELLOW}步骤 2: 检查测试文件...${NC}"

TEST_DIRS=(
    "VoiceTodoTests/Protocols"
    "VoiceTodoTests/Voice"
    "VoiceTodoTests/Extractor"
    "VoiceTodoTests/Store"
    "VoiceTodoTests/Integration"
    "VoiceTodoUITests"
)

for dir in "${TEST_DIRS[@]}"; do
    if [ -d "$PROJECT_ROOT/$dir" ]; then
        FILE_COUNT=$(find "$PROJECT_ROOT/$dir" -name "*.swift" | wc -l)
        echo -e "  ${GREEN}✓${NC} $dir ($FILE_COUNT 文件)"
    else
        echo -e "  ${RED}✗${NC} $dir (目录不存在)"
    fi
done

echo ""

# 步骤 3: 验证项目结构
echo -e "${YELLOW}步骤 3: 验证项目结构...${NC}"

DIRECTORY_STRUCTURE=(
    "App"
    "Voice"
    "Extractor"
    "Store"
    "UI/ConfirmSheet"
    "UI/Home"
    "UI/Shared"
    "UI/Widget"
    "Protocols"
)

ALL_DIRS_EXIST=true
for dir in "${DIRECTORY_STRUCTURE[@]}"; do
    if [ -d "$PROJECT_ROOT/$dir" ]; then
        echo -e "  ${GREEN}✓${NC} $dir"
    else
        echo -e "  ${RED}✗${NC} $dir (缺失)"
        ALL_DIRS_EXIST=false
    fi
done

echo ""

# 步骤 4: 创建临时文件列表
echo -e "${YELLOW}步骤 4: 创建文件列表（供 Xcode 参考）...${NC}"

# 主应用文件
MAIN_APP_FILES=$(cat <<EOF
# 主应用文件 (Target: VoiceTodo)
App/VoiceTodoApp.swift
App/AppCoordinator.swift
App/OnboardingView.swift
App/PermissionManager.swift
App/ServiceContainer+VoiceTodo.swift

Voice/VoiceInputManager.swift
Voice/AudioSessionHelper.swift
Voice/VoiceConstants.swift

Extractor/TodoExtractorService.swift
Extractor/PromptTemplates.swift
Extractor/NetworkClient.swift

Store/SwiftDataModels.swift
Store/TodoStore.swift
Store/AppGroupConfig.swift

UI/ConfirmSheet/ConfirmSheetView.swift
UI/ConfirmSheet/TodoItemRow.swift
UI/Home/HomeView.swift
UI/Shared/EmptyStateView.swift
UI/Shared/ToastView.swift

Protocols/Models.swift
Protocols/VoiceInputProtocol.swift
Protocols/TodoExtractorProtocol.swift
Protocols/TodoStoreProtocol.swift
Protocols/VoiceTodoError.swift
Protocols/ErrorMessages.swift
Protocols/Constants.swift
Protocols/ServiceContainer.swift
Protocols/KeychainHelper.swift
Protocols/NetworkMonitor.swift
EOF
)

echo "$MAIN_APP_FILES" > "$PROJECT_ROOT/.xcode_main_app_files.txt"
echo -e "  ${GREEN}✓${NC} 创建 .xcode_main_app_files.txt"

# Widget 文件
WIDGET_FILES=$(cat <<EOF
# Widget 文件 (Target: VoiceTodoWidget)
UI/Widget/TodoWidgetBundle.swift
UI/Widget/TodoWidgetProvider.swift
UI/Widget/TodoWidgetView.swift

Protocols/Models.swift
Protocols/VoiceTodoError.swift
Protocols/ErrorMessages.swift
Protocols/Constants.swift
EOF
)

echo "$WIDGET_FILES" > "$PROJECT_ROOT/.xcode_widget_files.txt"
echo -e "  ${GREEN}✓${NC} 创建 .xcode_widget_files.txt"

# 单元测试文件
UNIT_TEST_FILES=$(cat <<EOF
# 单元测试文件 (Target: VoiceTodoTests)
VoiceTodoTests/Protocols/ProtocolsTests.swift
VoiceTodoTests/Voice/VoiceInputTests.swift
VoiceTodoTests/Extractor/ExtractorTests.swift
VoiceTodoTests/Store/StoreTests.swift
VoiceTodoTests/Integration/IntegrationTests.swift
EOF
)

echo "$UNIT_TEST_FILES" > "$PROJECT_ROOT/.xcode_unit_test_files.txt"
echo -e "  ${GREEN}✓${NC} 创建 .xcode_unit_test_files.txt"

# UI 测试文件
UI_TEST_FILES=$(cat <<EOF
# UI 测试文件 (Target: VoiceTodoUITests)
VoiceTodoUITests/MockSetup.swift
VoiceTodoUITests/AppLaunchHelper.swift
VoiceTodoUITests/ScenarioTests.swift
VoiceTodoUITests/WidgetSnapshotTests.swift
EOF
)

echo "$UI_TEST_FILES" > "$PROJECT_ROOT/.xcode_ui_test_files.txt"
echo -e "  ${GREEN}✓${NC} 创建 .xcode_ui_test_files.txt"

echo ""

# 步骤 5: 检查 App Group 配置
echo -e "${YELLOW}步骤 5: App Group 配置提醒${NC}"
echo "  在 Xcode 中配置以下 App Group:"
echo "  - group.com.voicetodo.shared"
echo "  需要添加到以下 targets:"
echo "    • VoiceTodo (主应用)"
echo "    • VoiceTodoWidget (Widget Extension)"
echo ""

# 步骤 6: 生成项目配置清单
echo -e "${YELLOW}步骤 6: 生成配置清单...${NC}"

CONFIG_CHECKLIST=$(cat <<EOF
# VoiceTodo Xcode 项目配置清单

## 必需配置

### Targets
- [ ] VoiceTodo (iOS App)
- [ ] VoiceTodoTests (Unit Tests)
- [ ] VoiceTodoUITests (UI Tests)
- [ ] VoiceTodoWidget (Widget Extension)

### Capabilities
- [ ] App Groups (VoiceTodo): group.com.voicetodo.shared
- [ ] App Groups (VoiceTodoWidget): group.com.voicetodo.shared

### Build Settings
- [ ] iOS Deployment Target: 17.0
- [ ] Swift Language Version: 5
- [ ] Enable Testability: Yes (Debug)

### Frameworks
- [ ] SwiftData.framework
- [ ] Speech.framework
- [ ] AVFoundation.framework
- [ ] WidgetKit.framework (Widget only)
- [ ] SwiftData.framework (Widget only)

### File Target Memberships
- [ ] 主应用文件 → VoiceTodo
- [ ] 单元测试文件 → VoiceTodoTests
- [ ] UI 测试文件 → VoiceTodoUITests
- [ ] Widget 文件 → VoiceTodoWidget
- [ ] 共享协议文件 → VoiceTodo + VoiceTodoWidget + VoiceTodoTests

### Schemes
- [ ] VoiceTodo (包含测试)
- [ ] VoiceTodoWidget

## 可选配置

### Debug Settings
- [ ] Code Coverage: Enabled
- [ ] Thread Sanitizer: Enabled (Debug)
- [ ] Address Sanitizer: Enabled (Debug)

### CI/CD
- [ ] GitHub Actions 配置
- [ ] 自动化测试运行
- [ ] 代码覆盖率报告

## 验证步骤

1. [ ] 编译通过（无错误）
2. [ ] 运行单元测试
3. [ ] 运行 UI 测试
4. [ ] 测试 Widget 显示
5. [ ] 验证 App Group 数据共享

## 注意事项

⚠️ 确保 Widget Extension 的 Bundle ID 是主应用 Bundle ID 的子集
   例如: com.voicetodo.app.widget

⚠️ 所有 targets 使用相同的 App Group ID
   group.com.voicetodo.shared

⚠️ SwiftData ModelContainer 配置使用共享容器路径
EOF
)

echo "$CONFIG_CHECKLIST" > "$PROJECT_ROOT/CONFIGURATION_CHECKLIST.md"
echo -e "  ${GREEN}✓${NC} 创建 CONFIGURATION_CHECKLIST.md"

echo ""

# 最终总结
echo -e "${GREEN}==================================="
echo "准备工作完成！"
echo -e "===================================${NC}"
echo ""
echo "下一步操作:"
echo ""
echo "1. 📖 阅读 XCODE_PROJECT_SETUP.md 获取详细创建步骤"
echo "2. ✅ 参考 CONFIGURATION_CHECKLIST.md 进行配置"
echo "3. 📂 使用 .xcode_*_files.txt 文件列表添加文件到对应 target"
echo "4. 🚀 在 Xcode 中创建项目（参考步骤 1）"
echo ""
echo "提示: 创建项目时不要覆盖现有文件，而是使用 'Add Files' 添加现有文件"
echo ""

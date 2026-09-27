#!/bin/bash
# App Store 截图产出流水线(配套 VoiceTodoUITests/ScreenshotUITests.swift)。
# 产出 screenshots/{zh,en}/ 各 7 张、1320×2868(6.9" 档)PNG。
#
# 用法:./scripts/capture-screenshots.sh
# 环境覆盖:DEVICE_NAME(默认 iPhone 17 Pro Max)/ DEVICE_UDID(直接指定模拟器)。
#
# 注意:本机 Claude Code 等 Rosetta 进程调 xcodebuild 会连错模拟器设备集
# (Mach -308),所有 Xcode 工具链调用统一加 arch -arm64 前缀(原生 shell 下是无操作)。
set -euo pipefail

cd "$(dirname "$0")/.."

SCHEME="VoiceTodo"
TEST_TARGET="VoiceTodoUITests/ScreenshotUITests"
SCREENSHOTS_DIR="$PWD/screenshots"
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vt-shots.XXXXXX")"
RESULT_BUNDLE="$RUN_DIR/Screenshots.xcresult"

# 1. 解析模拟器(默认 iPhone 17 Pro Max = 6.9" 1320×2868;同名多台取第一台)
DEVICE_NAME="${DEVICE_NAME:-iPhone 17 Pro Max}"
if [[ -n "${DEVICE_UDID:-}" ]]; then
    UDID="$DEVICE_UDID"
else
    UDID="$(arch -arm64 xcrun simctl list devices available \
        | grep -m1 "$DEVICE_NAME (" \
        | sed -E 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/')"
fi
if [[ -z "$UDID" ]]; then
    echo "❌ 找不到可用模拟器:$DEVICE_NAME"
    exit 1
fi
echo "→ 设备:$DEVICE_NAME (UDID $UDID)"

# 2. 启动 + 等就绪(已启动时 boot 报错可忽略)
arch -arm64 xcrun simctl boot "$UDID" 2>/dev/null || true
arch -arm64 xcrun simctl bootstatus "$UDID" -b

# 3. 确定性状态栏(9:41 / 满电 / 满信号 / 无运营商名)+ 浅色外观
arch -arm64 xcrun simctl status_bar "$UDID" override \
    --time "9:41" \
    --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 \
    --operatorName "" \
    --batteryState discharging --batteryLevel 100
arch -arm64 xcrun simctl ui "$UDID" appearance light || true

# 4. 注册测试文件(project.yml glob VoiceTodoUITests 目录,新增文件需重新生成工程)。
#    xcodegen 不经 Rosetta 设备集,不加 arch 前缀(其二进制也不兼容该前缀)。
if command -v xcodegen >/dev/null 2>&1; then
    xcodegen generate
fi

# 4b.(已移除)曾尝试给 TestAction 注入 StoreKit 配置引用 —— iOS 26.5 运行时 +
#     xcodebuild CLI 下 scheme 级引用不生效(Apple 开发者论坛 826971,xctestplan
#     方案同样读不出)。现由测试内 app.launchEnvironment["SKStoreKitConfigurationPath"]
#     直接注入(Xcode 同款机制),脚本无需改 scheme。

# 5. 跑截图套件(仅该类)。SCREENSHOT_MODE 门禁经 TEST_RUNNER_ 前缀传入测试进程:
#    按手册 TEST_RUNNER_<VAR> 必须是**环境变量**(export/命令前缀),写成 xcodebuild
#    尾部参数会被当成构建设置覆盖而静默失效。
#    先清掉 14 个目标路径的旧产物:第 8 步按文件存在校验,残留旧图会掩盖本轮缺失。
export TEST_RUNNER_SCREENSHOT_MODE=1
for lang in zh en; do
    for shot in 01-recording 02-confirmsheet 03-month 04-today 05-review 06-paywall 07-onboarding; do
        rm -f "$SCREENSHOTS_DIR/$lang/$shot.png"
    done
done
# xcodebuild 非零退出不直接中断:个别流的收尾 terminate 曾挂死被判 "unexpected
# exit"(07 两张图其实已截到),在此中断会错过导出。失败在此大声警告,
# 最终以第 8 步的 14 张产物校验为准。
if ! arch -arm64 xcodebuild test \
    -project VoiceTodo.xcodeproj \
    -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,id=$UDID" \
    -only-testing:"$TEST_TARGET" \
    -resultBundlePath "$RESULT_BUNDLE"; then
    echo "⚠️ xcodebuild test 非零退出(详见上方日志),继续导出附件,以产物校验为准"
fi

# 6. 导出附件(xcresulttool 输出 PNG + manifest.json)
ATTACHMENTS_DIR="$RUN_DIR/attachments"
arch -arm64 xcrun xcresulttool export attachments \
    --path "$RESULT_BUNDLE" \
    --output-path "$ATTACHMENTS_DIR"

# 7. 按 manifest 分拣改名:附件名 NN-slug__lang → screenshots/{zh,en}/NN-slug.png
MANIFEST="$ATTACHMENTS_DIR/manifest.json"
if [[ ! -f "$MANIFEST" ]]; then
    echo "❌ 未找到 manifest.json,导出目录内容:"
    ls "$ATTACHMENTS_DIR"
    exit 1
fi

jq -r '.[] | .attachments[] | select(.isAssociatedWithFailure != true)
       | "\(.suggestedHumanReadableName)\t\(.exportedFileName)"' "$MANIFEST" \
| while IFS=$'\t' read -r attachName fileName; do
    [[ -n "$attachName" && "$attachName" == *__* ]] || continue
    lang="${attachName##*__}"
    base="${attachName%%__*}"
    mkdir -p "$SCREENSHOTS_DIR/$lang"
    cp "$ATTACHMENTS_DIR/$fileName" "$SCREENSHOTS_DIR/$lang/$base.png"
    echo "  ✓ $lang/$base.png"
done

# 8. 校验 14 张齐全 + 尺寸
EXPECTED=(01-recording 02-confirmsheet 03-month 04-today 05-review 06-paywall 07-onboarding)
MISSING=()
for lang in zh en; do
    for shot in "${EXPECTED[@]}"; do
        [[ -f "$SCREENSHOTS_DIR/$lang/$shot.png" ]] || MISSING+=("$lang/$shot.png")
    done
done
if (( ${#MISSING[@]} > 0 )); then
    echo "❌ 缺少 ${#MISSING[@]} 张截图:"
    printf '   %s\n' "${MISSING[@]}"
    echo "调试产物保留在:$RUN_DIR"
    exit 1
fi

echo "✓ 14 张截图齐全:"
for f in "$SCREENSHOTS_DIR"/zh/*.png "$SCREENSHOTS_DIR"/en/*.png; do
    dims="$(sips -g pixelWidth -g pixelHeight "$f" 2>/dev/null | awk '/pixel/{printf "%s×", $2}' | sed 's/×$//')"
    echo "   $f  ($dims)"
done
echo "调试产物(含 xcresult,确认无误后可删):$RUN_DIR"

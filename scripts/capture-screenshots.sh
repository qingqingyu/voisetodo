#!/bin/bash
# App Store 截图产出流水线(配套 VoiceTodoUITests/ScreenshotUITests.swift)。
# 产出 screenshots/{zh,en}/ 各 6 张、1320×2868(6.9" 档)PNG;
# 06-paywall 两张手动补(CLI 下 StoreKit 配置不生效,见测试文件内注释)。
#
# 用法:./scripts/capture-screenshots.sh
# 环境覆盖:DEVICE_NAME(默认 iPhone 17 Pro Max)/ DEVICE_UDID(直接指定模拟器)/
# EXPECTED_SIZE(默认 1320×2868;换 DEVICE_NAME 跑其他机型时同步覆盖)。
#
# 注意:本机 Claude Code 等 Rosetta 进程调 xcodebuild 会连错模拟器设备集
# (Mach -308),所有 Xcode 工具链调用统一加 arch -arm64 前缀(原生 shell 下是无操作)。
set -euo pipefail

cd "$(dirname "$0")/.."

SCHEME="VoiceTodo"
TEST_TARGET="VoiceTodoUITests/ScreenshotUITests"
SCREENSHOTS_DIR="$PWD/screenshots"
# 语言轮次与自动产物清单单源维护(加语言/画面只改这两行;Swift 侧对应
# ScreenshotUITests.languagePasses / capture 调用)。
LANGS=(zh en)
EXPECTED=(01-recording 02-confirmsheet 03-month 04-today 05-review 07-onboarding)
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vt-shots.XXXXXX")"
RESULT_BUNDLE="$RUN_DIR/Screenshots.xcresult"

# 1. 解析模拟器(默认 iPhone 17 Pro Max = 6.9" 1320×2868;同名多台取第一台)
DEVICE_NAME="${DEVICE_NAME:-iPhone 17 Pro Max}"
if [[ -n "${DEVICE_UDID:-}" ]]; then
    UDID="$DEVICE_UDID"
else
    # 尾接 || true:设备未命中时 grep 退出 1,若在此放任 set -euo pipefail
    # 击杀脚本,下方「找不到可用模拟器」的显式报错成死代码。
    UDID="$(arch -arm64 xcrun simctl list devices available \
        | grep -m1 "$DEVICE_NAME (" \
        | sed -E 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/' || true)"
fi
if [[ -z "$UDID" ]]; then
    echo "❌ 找不到可用模拟器:$DEVICE_NAME"
    exit 1
fi
echo "→ 设备:$DEVICE_NAME (UDID $UDID)"

# 2. 确保模拟器已启动。不做 shutdown/erase 冷重启 —— 实测(2026-09-27)冷启动后
#    的首个被测 app 启动会抖:automation session 拖 20~160s 甚至 kAXErrorServerNotFound
#    直接判死;热机(跑过至少一轮)后同样的启动 2s 内完成。app 数据干净由
#    --reset-user-data 保证,无需抹机。模拟器若真进坏状态,手动换
#    DEVICE_UDID 或重启 CoreSimulatorService 后重跑即可。
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

# 4b.(已移除)StoreKit 配置注入的两次尝试均失败 —— iOS 26.5 运行时 + xcodebuild
#     CLI 下 scheme TestAction 级引用不生效(Apple 开发者论坛 826971,xctestplan
#     方案同样读不出);测试内 app.launchEnvironment["SKStoreKitConfigurationPath"]
#     直接注入也绕不过。结论:CLI 驱动的付费墙恒错误态,06-paywall 两张改手动补
#     (Xcode GUI Run 的 StoreKit 配置生效)→ 设置 → 升级 Pro → Cmd+S,详见
#     ScreenshotUITests.runSeededFlow 内注释。

# 5. 跑截图套件(仅该类)。SCREENSHOT_MODE 门禁经 TEST_RUNNER_ 前缀传入测试进程:
#    按手册 TEST_RUNNER_<VAR> 必须是**环境变量**(export/命令前缀),写成 xcodebuild
#    尾部参数会被当成构建设置覆盖而静默失效。
#    先清掉 12 个自动产物路径:第 8 步按文件存在校验,残留旧图会掩盖本轮缺失
#    (06-paywall 为手动补图,不在清理与校验之列)。
export TEST_RUNNER_SCREENSHOT_MODE=1
for lang in "${LANGS[@]}"; do
    for shot in "${EXPECTED[@]}"; do
        rm -f "$SCREENSHOTS_DIR/$lang/$shot.png"
    done
done
# xcodebuild 非零退出不直接中断:个别流的收尾 terminate 曾挂死被判 "unexpected
# exit"(07 两张图其实已截到),在此中断会错过导出。失败在此大声警告,
# 最终以第 8 步的 12 张产物校验为准。
if ! arch -arm64 xcodebuild test \
    -project VoiceTodo.xcodeproj \
    -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,id=$UDID" \
    -only-testing:"$TEST_TARGET" \
    -resultBundlePath "$RESULT_BUNDLE"; then
    echo "⚠️ xcodebuild test 非零退出(详见上方日志),继续导出附件,以产物校验为准"
fi

# 6. 导出附件(xcresulttool 输出 PNG + manifest.json)
if [[ ! -d "$RESULT_BUNDLE" ]]; then
    echo "❌ 未产出 xcresult($RESULT_BUNDLE)——xcodebuild 在测试运行前即失败,无附件可导"
    exit 1
fi
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
       | (.suggestedHumanReadableName | sub("_[0-9]+_[0-9A-Fa-f-]{36}\\.png$"; "")) as $name
       | "\($name)\t\(.exportedFileName)"' "$MANIFEST" \
| while IFS=$'\t' read -r attachName fileName; do
    [[ -n "$attachName" && "$attachName" == *__* ]] || continue
    lang="${attachName##*__}"
    base="${attachName%%__*}"
    mkdir -p "$SCREENSHOTS_DIR/$lang"
    cp "$ATTACHMENTS_DIR/$fileName" "$SCREENSHOTS_DIR/$lang/$base.png"
    echo "  ✓ $lang/$base.png"
done

# 8. 校验 12 张齐全 + 尺寸(06-paywall 为手动补图,不在校验之列)
MISSING=()
WRONG_SIZE=()
EXPECTED_SIZE="${EXPECTED_SIZE:-1320×2868}"
for lang in "${LANGS[@]}"; do
    for shot in "${EXPECTED[@]}"; do
        f="$SCREENSHOTS_DIR/$lang/$shot.png"
        if [[ ! -f "$f" ]]; then
            MISSING+=("$lang/$shot.png")
            continue
        fi
        # || true:sips 硬失败(损坏 PNG)时落到空 dims → WRONG_SIZE 显式报错,
        # 而不是被 set -euo pipefail 在此静默击杀。
        dims="$(sips -g pixelWidth -g pixelHeight "$f" 2>/dev/null | awk '/pixel/{printf "%s×", $2}' | sed 's/×$//' || true)"
        [[ "$dims" == "$EXPECTED_SIZE" ]] || WRONG_SIZE+=("$lang/$shot.png($dims)")
    done
done
if (( ${#MISSING[@]} > 0 )); then
    echo "❌ 缺少 ${#MISSING[@]} 张截图:"
    printf '   %s\n' "${MISSING[@]}"
    echo "调试产物保留在:$RUN_DIR"
    exit 1
fi
if (( ${#WRONG_SIZE[@]} > 0 )); then
    echo "❌ ${#WRONG_SIZE[@]} 张尺寸 ≠ $EXPECTED_SIZE:"
    printf '   %s\n' "${WRONG_SIZE[@]}"
    echo "(换 DEVICE_NAME 跑其他机型时,用 EXPECTED_SIZE 环境变量覆盖)"
    echo "调试产物保留在:$RUN_DIR"
    exit 1
fi

echo "✓ $(( ${#LANGS[@]} * ${#EXPECTED[@]} )) 张截图齐全(尺寸 $EXPECTED_SIZE):"
for lang in "${LANGS[@]}"; do
    for shot in "${EXPECTED[@]}"; do
        echo "   $SCREENSHOTS_DIR/$lang/$shot.png"
    done
done
# 06-paywall 手动补图:只提醒、不校验、不影响退出码
for lang in "${LANGS[@]}"; do
    if [[ -f "$SCREENSHOTS_DIR/$lang/06-paywall.png" ]]; then
        echo "   $SCREENSHOTS_DIR/$lang/06-paywall.png  (手动补图,未校验)"
    else
        echo "⚠️ screenshots/$lang/06-paywall.png 待手动补(Xcode Run → 设置 → 升级 Pro → Cmd+S)"
    fi
done
echo "调试产物(含 xcresult,确认无误后可删):$RUN_DIR"

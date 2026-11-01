#!/bin/bash
# 宣传截图合成渲染器:Chrome headless 逐张渲染 marketing/compose/template.html
# 用法:
#   ./render.sh                      # 全套:01-07 × zh/en,定版风格 B(衬线暖纸)
#   ./render.sh --langs=en           # 只出 en(例如先上英文市场;等号形式,空格形式不识别)
# 产物:marketing/out/{lang}/{NN}.png(1320×2868);raw 缺失的序号渲染为占位卡
# 依赖:本机 Google Chrome + sips,零新增仓库依赖(CLAUDE.md 规则)
# 风格于 2026-10-28 三版小样拍板为 B(A/C 已删,历史见 git)

set -euo pipefail

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
ROOT="$(cd "$(dirname "$0")" && pwd)"        # marketing/
COMPOSE="$ROOT/compose"
OUT="$ROOT/out"
W=1320
H=2868
SHOTS="01 02 03 04 05 06 07"
LANGS="zh en"
STYLE="b"

for arg in "$@"; do
  case "$arg" in
    --langs=*) LANGS="${arg#--langs=}" ;;
    *) echo "ERROR: unknown argument: $arg (usage: [--langs=\"zh en\"])" >&2; exit 2 ;;
  esac
done

[[ -x "$CHROME" ]] || { echo "ERROR: Chrome 未找到:$CHROME" >&2; exit 1; }
[[ -f "$COMPOSE/template.html" ]] || { echo "ERROR: 模板缺失:$COMPOSE/template.html" >&2; exit 1; }
[[ -f "$COMPOSE/copy.js" ]] || { echo "ERROR: 文案缺失:$COMPOSE/copy.js" >&2; exit 1; }

# 渲染单张:render_one <lang> <shot> <variant> <输出路径>
render_one() {
  local lang="$1" shot="$2" variant="$3" dest="$4"
  mkdir -p "$(dirname "$dest")"
  local tmp_profile
  tmp_profile="$(mktemp -d)/profile"    # 独立 profile,避免与正在运行的 Chrome 冲突
  "$CHROME" --headless=new --disable-extensions --hide-scrollbars \
    --force-device-scale-factor=1 --window-size="${W},${H}" \
    --virtual-time-budget=5000 \
    --user-data-dir="$tmp_profile" \
    --screenshot="$dest" \
    "file://$COMPOSE/template.html#lang=$lang&shot=$shot&variant=$variant" \
    >/dev/null 2>&1
  rm -rf "$(dirname "$tmp_profile")"

  # 尺寸校验:不达标即失败,绝不静默放过
  local dim
  dim="$(sips -g pixelWidth -g pixelHeight "$dest" 2>/dev/null | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print w"x"h}')"
  if [[ "$dim" != "${W}x${H}" ]]; then
    echo "ERROR: $dest 渲染尺寸 $dim,期望 ${W}x${H}" >&2
    exit 1
  fi
  echo "  ✓ $dest ($dim)"
}

echo "== 全套:$SHOTS × $LANGS,风格 $STYLE(衬线暖纸)→ out/ =="
for lang in $LANGS; do
  for shot in $SHOTS; do
    render_one "$lang" "$shot" "$STYLE" "$OUT/$lang/$shot.png"
  done
done
echo "全部完成,共 $(( $(echo $LANGS | wc -w) * 7 )) 张。上传 ASC 前先人眼过一遍;raw 截图重产后重跑本脚本即可。"

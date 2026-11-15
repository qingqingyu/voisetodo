#!/bin/bash
# App Store 创意素材渲染器:产品页头图(ASC 中文界面「标题」)+ 搜索结果素材共用一张
# 用法:
#   ./render-header.sh                 # zh + en
#   ./render-header.sh --langs=en      # 只出 en(等号形式)
# 产物:marketing/out/header/{lang}.png,5244×2950(16:9,头图与搜索结果唯一共同支持的图片尺寸),无透明通道
# 模板:compose/header.html(CSS 2622×1475 × 2 倍渲染);自查安全区可浏览器打开 header.html#lang=en&guides=1
# 依赖:本机 Google Chrome + sips,与 render.sh 一致,零新增仓库依赖

set -euo pipefail

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
ROOT="$(cd "$(dirname "$0")" && pwd)"        # marketing/
COMPOSE="$ROOT/compose"
OUT="$ROOT/out/header"
CSS_W=2622
CSS_H=1475
W=5244
H=2950
LANGS="zh en"

for arg in "$@"; do
  case "$arg" in
    --langs=*) LANGS="${arg#--langs=}" ;;
    *) echo "ERROR: unknown argument: $arg (usage: [--langs=\"zh en\"])" >&2; exit 2 ;;
  esac
done

[[ -x "$CHROME" ]] || { echo "ERROR: Chrome 未找到:$CHROME" >&2; exit 1; }
[[ -f "$COMPOSE/header.html" ]] || { echo "ERROR: 模板缺失:$COMPOSE/header.html" >&2; exit 1; }
mkdir -p "$OUT"

for lang in $LANGS; do
  dest="$OUT/$lang.png"
  tmp_dir="$(mktemp -d)"
  "$CHROME" --headless=new --disable-extensions --hide-scrollbars \
    --force-device-scale-factor=2 --window-size="${CSS_W},${CSS_H}" \
    --virtual-time-budget=5000 \
    --user-data-dir="$tmp_dir/profile" \
    --screenshot="$tmp_dir/raw.png" \
    "file://$COMPOSE/header.html#lang=$lang" \
    >/dev/null 2>&1

  # ASC 拒收带 alpha 的图:经 JPEG(最高质量)中转去掉 alpha 通道再存回 PNG
  sips -s format jpeg -s formatOptions 100 "$tmp_dir/raw.png" --out "$tmp_dir/flat.jpg" >/dev/null
  sips -s format png "$tmp_dir/flat.jpg" --out "$dest" >/dev/null
  rm -rf "$tmp_dir"

  # 尺寸 + alpha 校验:不达标即失败
  info="$(sips -g pixelWidth -g pixelHeight -g hasAlpha "$dest" 2>/dev/null)"
  dim="$(echo "$info" | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print w"x"h}')"
  alpha="$(echo "$info" | awk '/hasAlpha/{print $2}')"
  if [[ "$dim" != "${W}x${H}" ]]; then
    echo "ERROR: $dest 渲染尺寸 $dim,期望 ${W}x${H}" >&2; exit 1
  fi
  if [[ "$alpha" == "yes" ]]; then
    echo "ERROR: $dest 仍含 alpha 通道" >&2; exit 1
  fi
  echo "  ✓ $dest ($dim, no alpha)"
done
echo "完成。上传前到 ASC 右上「预览」看各设备裁切效果;中文区在语言下拉切到「简体中文」后上传 zh.png。"

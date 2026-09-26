#!/bin/zsh
# 一键安装: 编译 → 安装到 /Applications → 启动
set -e
cd "$(dirname "$0")"

./build.sh

APP="/Applications/WorkBuddyTouchBar.app"
pkill -f WorkBuddyTouchBar 2>/dev/null || true
sleep 1
rm -rf "$APP"
cp -R "build/WorkBuddyTouchBar.app" "$APP"
open "$APP"

echo ""
echo "✅ 已安装并启动: $APP"
echo "   • 默认走 Pock 式全屏接管: 整条 Touch Bar 显示 ▶N xx% ⚡yy ✦zz + 任务名 + [详情] [✕]"
echo "   • 查看是否生效: cat /tmp/WorkBuddyTouchBar.log   (正常有 'Pock-e 全屏条已呈现')"
echo "   • 菜单栏 ⚡WB: Pock 式接管开关 / 控制条小件 / 立即刷新 / 复制 BTT 命令 / 生成预览图 / 开机自启"
echo "   • 自检: $APP/Contents/MacOS/WorkBuddyTouchBar --selftest"
echo "   • 预览: $APP/Contents/MacOS/WorkBuddyTouchBar --render /tmp/preview.png"

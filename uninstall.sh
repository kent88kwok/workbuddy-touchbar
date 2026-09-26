#!/bin/zsh
# 卸载
pkill -f WorkBuddyTouchBar 2>/dev/null || true
sleep 1
rm -rf /Applications/WorkBuddyTouchBar.app
rm -rf "$(dirname "$0")/build"
echo "✅ 已卸载 (若已开启开机自启, 请在系统设置→通用→登录项中删除 WorkBuddyTouchBar)"

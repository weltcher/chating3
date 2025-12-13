#!/bin/bash

# 修复 iOS 签名配置脚本

echo "🔧 修复 iOS 签名配置..."

PROJECT_FILE="ios/Runner.xcodeproj/project.pbxproj"

# 备份原文件
cp "$PROJECT_FILE" "${PROJECT_FILE}.backup"

# 使用 sed 替换所有的 Manual 为 Automatic
sed -i '' 's/CODE_SIGN_STYLE = Manual;/CODE_SIGN_STYLE = Automatic;/g' "$PROJECT_FILE"

# 移除空的 DEVELOPMENT_TEAM
sed -i '' 's/DEVELOPMENT_TEAM = "";/DEVELOPMENT_TEAM = P58DJ3X449;/g' "$PROJECT_FILE"

# 移除 PROVISIONING_PROFILE_SPECIFIER（Automatic 模式不
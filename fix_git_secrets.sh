#!/bin/bash

echo "=== 修复 Git 历史中的敏感信息 ==="
echo ""
echo "步骤 1: 从 git 缓存中移除敏感文件"
git rm --cached server/.env.product server/.env 2>/dev/null || true

echo ""
echo "步骤 2: 确保文件在 .gitignore 中"
if ! grep -q "^server/\.env\.product$" .gitignore; then
    echo "server/.env.product" >> .gitignore
fi
if ! grep -q "^server/\.env$" .gitignore; then
    echo "server/.env" >> .gitignore
fi

echo ""
echo "步骤 3: 提交更改"
git add .gitignore
git commit --amend --no-edit

echo ""
echo "=== 完成！现在可以强制推送 ==="
echo ""
echo "运行以下命令强制推送（会覆盖远程历史）："
echo "  git push origin main --force"
echo ""
echo "⚠️  警告：这会重写 git 历史！"
echo "⚠️  如果有其他人在使用这个仓库，请通知他们重新克隆。"

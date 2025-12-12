@echo off
chcp 65001 >nul
echo ========================================
echo 发布测试版本
echo ========================================
echo.

echo 正在发布 Windows 1.0.3 测试版本...
go run publish_version_simple.go ^
  -platform windows ^
  -version 1.0.3 ^
  -code 3 ^
  -url "https://youdu-chat2.oss-cn-beijing.aliyuncs.com/test/youdu_1.0.3.zip" ^
  -notes "测试版本：修复已知问题" ^
  -size 65000000 ^
  -publish

echo.
echo ========================================
echo 发布完成！
echo ========================================
pause

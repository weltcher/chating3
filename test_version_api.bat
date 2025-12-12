@echo off
chcp 65001 >nul
echo ========================================
echo 测试版本检查API
echo ========================================
echo.

echo 1. 测试Windows平台版本检查
curl "http://localhost:8080/api/version/check?platform=windows&current_version=1.0.0&version_code=1"
echo.
echo.

echo 2. 测试Android平台版本检查
curl "http://localhost:8080/api/version/check?platform=android&current_version=1.0.0&version_code=1"
echo.
echo.

echo 3. 测试iOS平台版本检查
curl "http://localhost:8080/api/version/check?platform=ios&current_version=1.0.0&version_code=1"
echo.
echo.

pause

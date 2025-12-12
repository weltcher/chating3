@echo off
chcp 65001 >nul
echo ========== 检查应用版本信息 ==========
echo.

set "RELEASE_DIR=C:\Users\WIN10\source\flutter\chat\youdu2\build\windows\x64\runner\tmp\Release"
set "DEBUG_DIR=C:\Users\WIN10\source\flutter\chat\youdu2\build\windows\x64\runner\Debug"

echo [1] 检查解压后的Release版本
echo 目录: %RELEASE_DIR%
if exist "%RELEASE_DIR%\youdu.exe" (
    echo ✓ youdu.exe 存在
    echo.
    echo 文件信息:
    powershell -Command "Get-Item '%RELEASE_DIR%\youdu.exe' | Select-Object Name, Length, LastWriteTime | Format-List"
    echo.
    echo 版本信息:
    powershell -Command "(Get-Item '%RELEASE_DIR%\youdu.exe').VersionInfo | Select-Object ProductVersion, FileVersion | Format-List"
) else (
    echo ✗ youdu.exe 不存在
)

echo.
echo ----------------------------------------
echo.

echo [2] 检查当前运行的Debug版本
echo 目录: %DEBUG_DIR%
if exist "%DEBUG_DIR%\youdu.exe" (
    echo ✓ youdu.exe 存在
    echo.
    echo 文件信息:
    powershell -Command "Get-Item '%DEBUG_DIR%\youdu.exe' | Select-Object Name, Length, LastWriteTime | Format-List"
    echo.
    echo 版本信息:
    powershell -Command "(Get-Item '%DEBUG_DIR%\youdu.exe').VersionInfo | Select-Object ProductVersion, FileVersion | Format-List"
) else (
    echo ✗ youdu.exe 不存在
)

echo.
echo ----------------------------------------
echo.

echo [3] 对比文件大小和修改时间
echo.
if exist "%RELEASE_DIR%\youdu.exe" (
    if exist "%DEBUG_DIR%\youdu.exe" (
        echo Release版本:
        dir "%RELEASE_DIR%\youdu.exe" | findstr "youdu.exe"
        echo.
        echo Debug版本:
        dir "%DEBUG_DIR%\youdu.exe" | findstr "youdu.exe"
        echo.
        echo 💡 提示:
        echo   - Release版本通常比Debug版本小很多
        echo   - 如果两个文件大小相同，说明可能打包错了
    )
)

echo.
echo ========== 检查完成 ==========
pause

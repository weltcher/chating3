@echo off
REM Redis stop script (Windows)

setlocal

set REDIS_PORT=6379
set REDIS_PASSWORD=XFqEKnqniTsEF3AidsFL

echo [INFO] Stopping Redis...

REM Try graceful shutdown
redis-cli -p %REDIS_PORT% -a %REDIS_PASSWORD% shutdown 2>nul
if %errorlevel% equ 0 (
    echo [SUCCESS] Redis stopped
    exit /b 0
)

REM If graceful shutdown fails, force kill process
taskkill /F /IM redis-server.exe >nul 2>nul
if %errorlevel% equ 0 (
    echo [SUCCESS] Redis process terminated
) else (
    echo [WARNING] Redis may not be running
)

endlocal

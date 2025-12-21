@echo off
REM Redis startup script (Windows)
REM Start Redis server in background

setlocal

REM Redis configuration
set REDIS_PORT=6379
set REDIS_PASSWORD=XFqEKnqniTsEF3AidsFL

REM Check if Redis is installed
where redis-server >nul 2>nul
if %errorlevel% neq 0 (
    echo [ERROR] redis-server not found, please install Redis first
    echo Download: https://github.com/tporadowski/redis/releases
    pause
    exit /b 1
)

REM Check if Redis is already running
netstat -an | findstr ":%REDIS_PORT%" | findstr "LISTENING" >nul 2>nul
if %errorlevel% equ 0 (
    echo [INFO] Redis is already running on port %REDIS_PORT%
    exit /b 0
)

echo [INFO] Starting Redis server...
echo [INFO] Port: %REDIS_PORT%

REM Start Redis in background
start /B redis-server --port %REDIS_PORT% --requirepass %REDIS_PASSWORD% --daemonize no

REM Wait for Redis to start
timeout /t 2 /nobreak >nul

REM Verify Redis started successfully
netstat -an | findstr ":%REDIS_PORT%" | findstr "LISTENING" >nul 2>nul
if %errorlevel% equ 0 (
    echo [SUCCESS] Redis started on port %REDIS_PORT%
) else (
    echo [ERROR] Failed to start Redis
    exit /b 1
)

endlocal

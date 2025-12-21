#!/bin/bash
# Redis stop script (Linux/macOS)

REDIS_PORT=6379
REDIS_PASSWORD="XFqEKnqniTsEF3AidsFL"
REDIS_LOG_DIR="$(dirname "$0")/logs"
REDIS_PID_FILE="$REDIS_LOG_DIR/redis.pid"

echo "[INFO] Stopping Redis..."

# Try graceful shutdown
if redis-cli -p $REDIS_PORT -a "$REDIS_PASSWORD" shutdown 2>/dev/null; then
    echo "[SUCCESS] Redis stopped"
    rm -f "$REDIS_PID_FILE"
    exit 0
fi

# If graceful shutdown fails, try to stop via PID file
if [ -f "$REDIS_PID_FILE" ]; then
    PID=$(cat "$REDIS_PID_FILE")
    if ps -p $PID > /dev/null 2>&1; then
        kill $PID
        sleep 1
        if ! ps -p $PID > /dev/null 2>&1; then
            echo "[SUCCESS] Redis stopped (PID: $PID)"
            rm -f "$REDIS_PID_FILE"
            exit 0
        fi
    fi
fi

echo "[WARNING] Redis may not be running"

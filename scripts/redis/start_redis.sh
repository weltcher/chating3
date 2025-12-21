#!/bin/bash
# Redis startup script (Linux/macOS)
# Start Redis server in background

# Redis configuration
REDIS_PORT=6379
REDIS_PASSWORD="XFqEKnqniTsEF3AidsFL"
REDIS_LOG_DIR="$(dirname "$0")/logs"
REDIS_LOG_FILE="$REDIS_LOG_DIR/redis.log"
REDIS_PID_FILE="$REDIS_LOG_DIR/redis.pid"

# Create log directory
mkdir -p "$REDIS_LOG_DIR"

# Check if Redis is installed
if ! command -v redis-server &> /dev/null; then
    echo "[ERROR] redis-server not found, please install Redis first"
    echo "  macOS: brew install redis"
    echo "  Ubuntu: sudo apt install redis-server"
    echo "  CentOS: sudo yum install redis"
    exit 1
fi

# Check if Redis is already running
if [ -f "$REDIS_PID_FILE" ]; then
    PID=$(cat "$REDIS_PID_FILE")
    if ps -p $PID > /dev/null 2>&1; then
        echo "[INFO] Redis is already running (PID: $PID)"
        exit 0
    else
        rm -f "$REDIS_PID_FILE"
    fi
fi

# Check if port is in use
if lsof -i:$REDIS_PORT > /dev/null 2>&1; then
    echo "[INFO] Port $REDIS_PORT is in use, Redis may already be running"
    exit 0
fi

echo "[INFO] Starting Redis server..."
echo "[INFO] Port: $REDIS_PORT"
echo "[INFO] Log: $REDIS_LOG_FILE"

# Start Redis in background
nohup redis-server \
    --port $REDIS_PORT \
    --requirepass "$REDIS_PASSWORD" \
    --daemonize no \
    >> "$REDIS_LOG_FILE" 2>&1 &

# Save PID
echo $! > "$REDIS_PID_FILE"

# Wait for Redis to start
sleep 2

# Verify Redis started successfully
if redis-cli -p $REDIS_PORT -a "$REDIS_PASSWORD" ping 2>/dev/null | grep -q "PONG"; then
    echo "[SUCCESS] Redis started"
    echo "  PID: $(cat $REDIS_PID_FILE)"
    echo "  Port: $REDIS_PORT"
else
    echo "[ERROR] Failed to start Redis, check log: $REDIS_LOG_FILE"
    exit 1
fi

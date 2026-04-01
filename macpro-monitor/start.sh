#!/bin/bash
cd "$(dirname "$0")"

# Stop existing server if running
if [ -f server.pid ] && kill -0 $(cat server.pid) 2>/dev/null; then
    echo "Stopping existing server..."
    kill $(cat server.pid) 2>/dev/null
    rm -f server.pid
    sleep 1
fi

# CLEAR GHOST DATA
echo "Clearing previous installation logs..."
rm -rf logs

# Start fresh
nohup node server.js > server.log 2>&1 &
echo $! > server.pid
sleep 2
echo "Server started (PID: $(cat server.pid))"

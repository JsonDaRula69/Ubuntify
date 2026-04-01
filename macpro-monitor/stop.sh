#!/bin/bash
cd "$(dirname "$0")"
[ -f server.pid ] && kill $(cat server.pid) 2>/dev/null && echo "Server stopped" && rm -f server.pid || echo "Server not running"

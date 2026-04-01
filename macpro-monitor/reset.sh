#!/bin/bash
cd ~/Desktop/Mac/macpro-monitor
./stop.sh
pkill -f "node server.js" 2>/dev/null || true
rm -rf logs server.pid server.log 2>/dev/null || true

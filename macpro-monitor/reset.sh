#!/bin/bash

pw=$(security find-generic-password -a "$USER" -s "TSudo" -w)

# Exit if the password couldn't be retrieved
if [ -z "$pw" ]; then
    echo "Error: Password not found in Keychain."
    exit 1
fi

cd "$(dirname "$0")" || exit

echo "$pw" | sudo -S ./stop.sh 2>/dev/null || true
echo "$pw" | sudo -S pkill -f "node server.js" 2>/dev/null || true
echo "$pw" | sudo -S rm -rf ./logs ./server.pid ./server.log

unset pw
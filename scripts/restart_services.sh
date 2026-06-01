#!/bin/bash
set -ex
cd /opt/proyecto-asg

pkill -f "monitor_s.collector" 2>/dev/null || true
pkill -f "controller_asg.controller" 2>/dev/null || true
sleep 1

set -a
source .env
set +a

export PYTHONUNBUFFERED=1
nohup python3 -u -m monitor_s.collector > /var/log/monitor_s.log 2>&1 &
nohup python3 -u -m controller_asg.controller > /var/log/controller_asg.log 2>&1 &

echo "Services restarted. PID monitor_s=$! controller_asg=$(pgrep -f controller_asg)"

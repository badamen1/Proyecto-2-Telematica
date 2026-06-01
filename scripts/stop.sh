#!/bin/bash
pkill -f "controller_asg.controller" 2>/dev/null || true
pkill -f "monitor_s.collector" 2>/dev/null || true
echo "All services stopped"

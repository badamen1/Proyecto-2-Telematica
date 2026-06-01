#!/bin/bash
set -ex
apt-get update -y
apt-get install -y python3 python3-pip git
pip3 install grpcio==1.66.2 grpcio-tools==1.66.2 redis==5.0.1 boto3==1.34.0 python-dotenv==1.0.1
mkdir -p /opt/proyecto-asg
cd /opt/proyecto-asg
git clone https://github.com/badamen1/Proyecto-2-Telematica.git .
# NO regenerar stubs - los del repo tienen imports relativos correctos
cp monitor_c/monitor_c.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable monitor_c
echo "=== AMI v2 SETUP COMPLETE ==="

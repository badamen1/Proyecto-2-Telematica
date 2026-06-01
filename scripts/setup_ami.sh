#!/bin/bash
set -ex

# ── Instalar dependencias del sistema ──
apt-get update -y
apt-get install -y python3 python3-pip git

# ── Clonar el repositorio ──
mkdir -p /opt/proyecto-asg
cd /opt/proyecto-asg
git clone https://github.com/badamen1/Proyecto-2-Telematica.git .

# ── Instalar dependencias Python ──
pip3 install grpcio==1.66.2 grpcio-tools==1.66.2 redis==5.0.1 boto3==1.34.0 python-dotenv==1.0.1

# ── Generar stubs gRPC ──
python3 -m grpc_tools.protoc -I proto --python_out=proto --grpc_python_out=proto proto/monitor.proto

# ── Instalar servicio systemd de MonitorC ──
cp monitor_c/monitor_c.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable monitor_c

echo "=== AMI SETUP COMPLETE ==="

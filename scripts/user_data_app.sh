#!/bin/bash
set -e

apt-get update -y
apt-get install -y python3 python3-pip git

pip3 install grpcio==1.66.2 grpcio-tools==1.66.2 redis==5.0.1 boto3==1.34.0

mkdir -p /opt/proyecto-asg
cd /opt/proyecto-asg

# Clonar el repositorio del proyecto
# git clone <REPO_URL> .

# Generar stubs gRPC
python3 -m grpc_tools.protoc -I proto --python_out=proto --grpc_python_out=proto proto/monitor.proto

# Instalar y arrancar el servicio systemd de MonitorC
cp monitor_c/monitor_c.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable monitor_c
systemctl start monitor_c

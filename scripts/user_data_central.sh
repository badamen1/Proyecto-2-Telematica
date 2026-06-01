#!/bin/bash
set -e

apt-get update -y
apt-get install -y python3 python3-pip git redis-server

systemctl enable redis-server
systemctl start redis-server

pip3 install grpcio==1.66.2 grpcio-tools==1.66.2 redis==5.0.1 boto3==1.34.0 python-dotenv==1.0.1

mkdir -p /opt/proyecto-asg
cd /opt/proyecto-asg

# Clonar el repositorio del proyecto
# git clone <REPO_URL> .

# Generar stubs gRPC
python3 -m grpc_tools.protoc -I proto --python_out=proto --grpc_python_out=proto proto/monitor.proto

# La IP privada de esta instancia se inyecta en .env para que la lean los procesos Python
MONITOR_S_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
echo "MONITOR_S_IP=$MONITOR_S_IP" >> /opt/proyecto-asg/.env

# Cargar .env en la shell para que los nohup hereden las variables
set -a
source /opt/proyecto-asg/.env
set +a

# Arrancar MonitorS y ControllerASG como procesos en background
nohup python3 /opt/proyecto-asg/monitor_s/collector.py \
    > /var/log/monitor_s.log 2>&1 &

nohup python3 /opt/proyecto-asg/controller_asg/controller.py \
    > /var/log/controller_asg.log 2>&1 &

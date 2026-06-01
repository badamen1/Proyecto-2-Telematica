#!/bin/bash
set -ex

apt-get update -y
apt-get install -y python3 python3-pip git redis-server

systemctl enable redis-server
systemctl start redis-server

pip3 install grpcio==1.66.2 grpcio-tools==1.66.2 redis==5.0.1 boto3==1.34.0 python-dotenv==1.0.1

mkdir -p /opt/proyecto-asg
cd /opt/proyecto-asg

# Clonar el repositorio del proyecto
git clone https://github.com/badamen1/Proyecto-2-Telematica.git .

# Generar stubs gRPC
python3 -m grpc_tools.protoc -I proto --python_out=proto --grpc_python_out=proto proto/monitor.proto

# La IP privada de esta instancia se inyecta en .env para que la lean los procesos Python
MONITOR_S_IP=$(curl -s http://169.254.169.254/latest/api/token -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null && curl -s -H "X-aws-ec2-metadata-token: $(curl -s -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')" http://169.254.169.254/latest/meta-data/local-ipv4 || curl -s http://169.254.169.254/latest/meta-data/local-ipv4)

# Crear archivo .env con la configuración real
cat > /opt/proyecto-asg/.env <<EOF
AMI_ID=ami-01c60b58d89155dd9
SUBNET_ID=subnet-09d880695a1897d15
SECURITY_GROUP_ID=sg-01632f6662a14a26a
TARGET_GROUP_ARN=arn:aws:elasticloadbalancing:us-east-1:634756923528:targetgroup/proyecto-asg-tg/5e9d8918dbf42dcb
MONITOR_S_IP=$MONITOR_S_IP
KEY_NAME=vockey
AWS_REGION=us-east-1
REDIS_HOST=localhost
REDIS_PORT=6379
EOF

# Cargar .env en la shell para que los nohup hereden las variables
set -a
source /opt/proyecto-asg/.env
set +a

# Arrancar MonitorS y ControllerASG como procesos en background
nohup python3 -m monitor_s.collector \
    > /var/log/monitor_s.log 2>&1 &

nohup python3 -m controller_asg.controller \
    > /var/log/controller_asg.log 2>&1 &

echo "=== CENTRAL INSTANCE SETUP COMPLETE ==="

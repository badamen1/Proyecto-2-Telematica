<#
.SYNOPSIS
  Script IDEMPOTENTE para desplegar el proyecto ASG en AWS Free Tier.
  Puedes ejecutarlo las veces que quieras y siempre obtendrás el mismo resultado.

.USAGE
  .\scripts\deploy.ps1
#>

$ErrorActionPreference = "Stop"
$REGION = "us-east-1"
$PROJECT = "proyecto-asg"
$VPC_ID = "vpc-0f4f0d948f5300bb5"
$SUBNET_A = "subnet-09d880695a1897d15"   # us-east-1a
$SUBNET_B = "subnet-0ffe59720c037255b"   # us-east-1b
$AMI_ID = "ami-0cc91ae6b839562b3"         # AMI custom con MonitorC
$INSTANCE_TYPE = "t3.micro"
$KEY_NAME = "vockey"
$PEM_PATH = "$env:USERPROFILE\.ssh\vockey.pem"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  DEPLOY: Proyecto ASG - AWS Free Tier" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# ── Paso 1: Limpiar instancias anteriores ──────────────────────────────────
Write-Host "[1/7] Limpiando instancias anteriores..." -ForegroundColor Yellow

$oldCentral = aws ec2 describe-instances --filters "Name=tag:Name,Values=CentralInstance" "Name=instance-state-name,Values=running,pending" --query "Reservations[*].Instances[*].InstanceId" --output text --region $REGION 2>$null
if ($oldCentral -and $oldCentral -ne "None") {
    $ids = $oldCentral -split '\s+'
    foreach ($id in $ids) {
        if ($id -and $id -ne "") {
            Write-Host "  Terminando instancia central: $id"
            aws ec2 terminate-instances --instance-ids $id --region $REGION --output text 2>$null | Out-Null
        }
    }
}

$oldApps = aws ec2 describe-instances --filters "Name=tag:Role,Values=AppInstance" "Name=instance-state-name,Values=running,pending" --query "Reservations[*].Instances[*].InstanceId" --output text --region $REGION 2>$null
if ($oldApps -and $oldApps -ne "None") {
    $ids = $oldApps -split '\s+'
    foreach ($id in $ids) {
        if ($id -and $id -ne "") {
            Write-Host "  Terminando AppInstance: $id"
            aws ec2 terminate-instances --instance-ids $id --region $REGION --output text 2>$null | Out-Null
        }
    }
}

Write-Host "  OK - Instancias anteriores eliminadas" -ForegroundColor Green

# ── Paso 2: Security Group (idempotente) ───────────────────────────────────
Write-Host "[2/7] Verificando Security Group..." -ForegroundColor Yellow

$SG_ID = aws ec2 describe-security-groups --filters "Name=group-name,Values=$PROJECT-sg" --query "SecurityGroups[0].GroupId" --output text --region $REGION 2>$null
if ($SG_ID -eq "None" -or -not $SG_ID) {
    Write-Host "  Creando Security Group..."
    $SG_ID = aws ec2 create-security-group --group-name "$PROJECT-sg" --description "SG para proyecto ASG" --vpc-id $VPC_ID --query "GroupId" --output text --region $REGION
    aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 22 --cidr 0.0.0.0/0 --region $REGION 2>$null | Out-Null
    aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 50051 --source-group $SG_ID --region $REGION 2>$null | Out-Null
    aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 6379 --source-group $SG_ID --region $REGION 2>$null | Out-Null
    aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 80 --cidr 0.0.0.0/0 --region $REGION 2>$null | Out-Null
} 
Write-Host "  OK - Security Group: $SG_ID" -ForegroundColor Green

# ── Paso 3: Key Pair (recrear siempre para garantizar acceso SSH) ──────────
Write-Host "[3/7] Configurando Key Pair..." -ForegroundColor Yellow

# Eliminar key pair anterior si existe
aws ec2 delete-key-pair --key-name $KEY_NAME --region $REGION 2>$null | Out-Null
if (Test-Path $PEM_PATH) { 
    icacls $PEM_PATH /grant:r "$($env:USERNAME):(F)" 2>$null | Out-Null
    Remove-Item -Force $PEM_PATH -ErrorAction SilentlyContinue 
}

# Crear nuevo key pair usando JSON para preservar saltos de linea
$keyJson = aws ec2 create-key-pair --key-name $KEY_NAME --output json --region $REGION | ConvertFrom-Json
[System.IO.File]::WriteAllText($PEM_PATH, $keyJson.KeyMaterial)
icacls $PEM_PATH /inheritance:r /grant:r "$($env:USERNAME):(R)" | Out-Null
Write-Host "  OK - Key Pair: $KEY_NAME ($PEM_PATH)" -ForegroundColor Green

# ── Paso 4: Target Group (idempotente) ─────────────────────────────────────
Write-Host "[4/7] Verificando Target Group..." -ForegroundColor Yellow

$TG_ARN = aws elbv2 describe-target-groups --names "$PROJECT-tg" --query "TargetGroups[0].TargetGroupArn" --output text --region $REGION 2>$null
if (-not $TG_ARN -or $TG_ARN -eq "None") {
    Write-Host "  Creando Target Group..."
    $TG_ARN = aws elbv2 create-target-group --name "$PROJECT-tg" --protocol HTTP --port 80 --vpc-id $VPC_ID --health-check-protocol HTTP --health-check-path / --target-type instance --query "TargetGroups[0].TargetGroupArn" --output text --region $REGION
}
Write-Host "  OK - Target Group: $TG_ARN" -ForegroundColor Green

# ── Paso 5: ALB (idempotente) ──────────────────────────────────────────────
Write-Host "[5/7] Verificando ALB..." -ForegroundColor Yellow

$ALB_ARN = aws elbv2 describe-load-balancers --names "$PROJECT-alb" --query "LoadBalancers[0].LoadBalancerArn" --output text --region $REGION 2>$null
if (-not $ALB_ARN -or $ALB_ARN -eq "None") {
    Write-Host "  Creando ALB..."
    $albJson = aws elbv2 create-load-balancer --name "$PROJECT-alb" --subnets $SUBNET_A $SUBNET_B --security-groups $SG_ID --scheme internet-facing --type application --query "LoadBalancers[0]" --output json --region $REGION | ConvertFrom-Json
    $ALB_ARN = $albJson.LoadBalancerArn
    $ALB_DNS = $albJson.DNSName

    # Crear listener
    aws elbv2 create-listener --load-balancer-arn $ALB_ARN --protocol HTTP --port 80 --default-actions "Type=forward,TargetGroupArn=$TG_ARN" --region $REGION --output text 2>$null | Out-Null
} else {
    $ALB_DNS = aws elbv2 describe-load-balancers --names "$PROJECT-alb" --query "LoadBalancers[0].DNSName" --output text --region $REGION
}
Write-Host "  OK - ALB: $ALB_DNS" -ForegroundColor Green

# ── Paso 6: IAM Instance Profile (idempotente) ────────────────────────────
Write-Host "[6/7] Verificando IAM Role e Instance Profile..." -ForegroundColor Yellow

$roleExists = aws iam get-role --role-name "$PROJECT-ec2-role" --query "Role.RoleName" --output text --region $REGION 2>$null
if (-not $roleExists -or $roleExists -eq "None") {
    # Crear trust policy file
    $trustPolicy = '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
    $trustPolicy | Out-File -Encoding ascii -FilePath "$env:TEMP\trust-policy.json" -NoNewline
    aws iam create-role --role-name "$PROJECT-ec2-role" --assume-role-policy-document "file://$env:TEMP\trust-policy.json" --region $REGION --output text 2>$null | Out-Null
    aws iam attach-role-policy --role-name "$PROJECT-ec2-role" --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess --region $REGION 2>$null
    aws iam attach-role-policy --role-name "$PROJECT-ec2-role" --policy-arn arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess --region $REGION 2>$null
}

$profileExists = aws iam get-instance-profile --instance-profile-name "$PROJECT-profile" --query "InstanceProfile.InstanceProfileName" --output text --region $REGION 2>$null
if (-not $profileExists -or $profileExists -eq "None") {
    aws iam create-instance-profile --instance-profile-name "$PROJECT-profile" --region $REGION --output text 2>$null | Out-Null
    aws iam add-role-to-instance-profile --instance-profile-name "$PROJECT-profile" --role-name "$PROJECT-ec2-role" --region $REGION 2>$null
    Start-Sleep -Seconds 10  # Esperar propagación IAM
}
Write-Host "  OK - IAM Role e Instance Profile listos" -ForegroundColor Green

# ── Paso 7: Lanzar instancia central ──────────────────────────────────────
Write-Host "[7/7] Lanzando instancia central..." -ForegroundColor Yellow

# Generar user_data dinámico con los valores reales
$userData = @"
#!/bin/bash
set -ex
apt-get update -y
apt-get install -y python3 python3-pip git redis-server
systemctl enable redis-server
systemctl start redis-server
pip3 install grpcio==1.66.2 grpcio-tools==1.66.2 redis==5.0.1 boto3==1.34.0 python-dotenv==1.0.1
mkdir -p /opt/proyecto-asg && cd /opt/proyecto-asg
git clone https://github.com/badamen1/Proyecto-2-Telematica.git .
# Los stubs gRPC ya estan en el repo con imports relativos correctos - NO regenerar
TOKEN=`$(curl -s -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)
if [ -n "`$TOKEN" ]; then
  MY_IP=`$(curl -s -H "X-aws-ec2-metadata-token: `$TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)
else
  MY_IP=`$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
fi
cat > /opt/proyecto-asg/.env <<EOF
AMI_ID=$AMI_ID
SUBNET_ID=$SUBNET_A
SECURITY_GROUP_ID=$SG_ID
TARGET_GROUP_ARN=$TG_ARN
MONITOR_S_IP=`$MY_IP
KEY_NAME=$KEY_NAME
AWS_REGION=$REGION
REDIS_HOST=localhost
REDIS_PORT=6379
EOF
set -a && source /opt/proyecto-asg/.env && set +a
export PYTHONUNBUFFERED=1
nohup python3 -u -m monitor_s.collector > /var/log/monitor_s.log 2>&1 &
nohup python3 -u -m controller_asg.controller > /var/log/controller_asg.log 2>&1 &
echo '=== CENTRAL SETUP COMPLETE ==='
"@

$bytes = [System.Text.Encoding]::UTF8.GetBytes($userData)
$b64 = [Convert]::ToBase64String($bytes)

$instanceJson = aws ec2 run-instances `
    --image-id ami-02fd066b86800f60c `
    --instance-type $INSTANCE_TYPE `
    --key-name $KEY_NAME `
    --security-group-ids $SG_ID `
    --subnet-id $SUBNET_A `
    --user-data $b64 `
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=CentralInstance}]" `
    --iam-instance-profile Name="$PROJECT-profile" `
    --query "Instances[0]" `
    --output json `
    --region $REGION | ConvertFrom-Json

$CENTRAL_ID = $instanceJson.InstanceId
Write-Host "  Instancia lanzada: $CENTRAL_ID" -ForegroundColor Cyan
Write-Host "  Esperando que esté running..." -ForegroundColor Cyan

aws ec2 wait instance-running --instance-ids $CENTRAL_ID --region $REGION

$centralInfo = aws ec2 describe-instances --instance-ids $CENTRAL_ID --query "Reservations[0].Instances[0].{PublicIp:PublicIpAddress,PrivateIp:PrivateIpAddress}" --output json --region $REGION | ConvertFrom-Json

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  DEPLOY EXITOSO!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Instancia Central: $CENTRAL_ID" -ForegroundColor White
Write-Host "  IP Publica:        $($centralInfo.PublicIp)" -ForegroundColor White
Write-Host "  IP Privada:        $($centralInfo.PrivateIp)" -ForegroundColor White
Write-Host "  ALB DNS:           $ALB_DNS" -ForegroundColor White
Write-Host "  Security Group:    $SG_ID" -ForegroundColor White
Write-Host "  Target Group:      $TG_ARN" -ForegroundColor White
Write-Host ""
Write-Host "  SSH:" -ForegroundColor Yellow
Write-Host "    ssh -i $PEM_PATH ubuntu@$($centralInfo.PublicIp)" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Espera ~3-5 min para que el User Data termine." -ForegroundColor Yellow
Write-Host "  Luego usa .\scripts\monitor.ps1 para ver el scaling." -ForegroundColor Yellow
Write-Host ""

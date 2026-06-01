<#
.SYNOPSIS
  Apaga TODO el proyecto ASG. Ejecutar SIEMPRE al terminar de probar.
  
.USAGE
  .\scripts\cleanup.ps1              # Termina instancias (mantiene infra)
  .\scripts\cleanup.ps1 -DestroyAll  # Borra TODO (SG, ALB, TG, IAM, AMI)
#>

param(
    [switch]$DestroyAll
)

$ErrorActionPreference = "Continue"
$REGION = "us-east-1"
$PROJECT = "proyecto-asg"

Write-Host "`n========================================" -ForegroundColor Red
Write-Host "  CLEANUP: Proyecto ASG" -ForegroundColor Red
Write-Host "========================================`n" -ForegroundColor Red

# ── 1. Terminar TODAS las instancias del proyecto ──
Write-Host "[1] Terminando instancias..." -ForegroundColor Yellow

$allInstances = aws ec2 describe-instances `
    --filters "Name=instance-state-name,Values=running,pending,stopping,stopped" `
    --query "Reservations[*].Instances[?Tags[?Key=='Name'&&Value=='CentralInstance']||Tags[?Key=='Role'&&Value=='AppInstance']].InstanceId" `
    --output text --region $REGION 2>$null

if ($allInstances -and $allInstances -ne "None" -and $allInstances.Trim() -ne "") {
    $ids = ($allInstances -split '\s+') | Where-Object { $_ -ne "" }
    foreach ($id in $ids) {
        Write-Host "  Terminando: $id"
        aws ec2 terminate-instances --instance-ids $id --region $REGION --output text 2>$null | Out-Null
    }
    Write-Host "  Esperando que terminen..."
    aws ec2 wait instance-terminated --instance-ids $ids --region $REGION 2>$null
} else {
    Write-Host "  No hay instancias activas."
}
Write-Host "  OK" -ForegroundColor Green

if (-not $DestroyAll) {
    Write-Host "`nInstancias terminadas. La infraestructura (SG, ALB, AMI) se mantiene." -ForegroundColor Cyan
    Write-Host "Para destruir todo: .\scripts\cleanup.ps1 -DestroyAll`n" -ForegroundColor Cyan
    exit 0
}

# ── 2. Eliminar ALB ──
Write-Host "[2] Eliminando ALB..." -ForegroundColor Yellow
$albArn = aws elbv2 describe-load-balancers --names "$PROJECT-alb" --query "LoadBalancers[0].LoadBalancerArn" --output text --region $REGION 2>$null
if ($albArn -and $albArn -ne "None") {
    aws elbv2 delete-load-balancer --load-balancer-arn $albArn --region $REGION 2>$null
    Write-Host "  ALB eliminado"
}

# ── 3. Eliminar Target Group ──
Write-Host "[3] Eliminando Target Group..." -ForegroundColor Yellow
Start-Sleep -Seconds 5  # Esperar a que el ALB se libere
$tgArn = aws elbv2 describe-target-groups --names "$PROJECT-tg" --query "TargetGroups[0].TargetGroupArn" --output text --region $REGION 2>$null
if ($tgArn -and $tgArn -ne "None") {
    aws elbv2 delete-target-group --target-group-arn $tgArn --region $REGION 2>$null
    Write-Host "  Target Group eliminado"
}

# ── 4. Eliminar Security Group ──
Write-Host "[4] Eliminando Security Group..." -ForegroundColor Yellow
Start-Sleep -Seconds 10  # Esperar a que las ENIs se liberen
$sgId = aws ec2 describe-security-groups --filters "Name=group-name,Values=$PROJECT-sg" --query "SecurityGroups[0].GroupId" --output text --region $REGION 2>$null
if ($sgId -and $sgId -ne "None") {
    aws ec2 delete-security-group --group-id $sgId --region $REGION 2>$null
    Write-Host "  Security Group eliminado"
}

# ── 5. Eliminar Key Pair ──
Write-Host "[5] Eliminando Key Pair..." -ForegroundColor Yellow
aws ec2 delete-key-pair --key-name vockey --region $REGION 2>$null
Write-Host "  Key Pair eliminado"

# ── 6. Eliminar AMI y snapshot ──
Write-Host "[6] Eliminando AMI..." -ForegroundColor Yellow
$amiId = aws ec2 describe-images --owners self --filters "Name=name,Values=$PROJECT-app-v1" --query "Images[0].ImageId" --output text --region $REGION 2>$null
if ($amiId -and $amiId -ne "None") {
    $snapId = aws ec2 describe-images --image-ids $amiId --query "Images[0].BlockDeviceMappings[0].Ebs.SnapshotId" --output text --region $REGION 2>$null
    aws ec2 deregister-image --image-id $amiId --region $REGION 2>$null
    if ($snapId -and $snapId -ne "None") {
        aws ec2 delete-snapshot --snapshot-id $snapId --region $REGION 2>$null
    }
    Write-Host "  AMI y snapshot eliminados"
}

# ── 7. Eliminar IAM ──
Write-Host "[7] Eliminando IAM Role e Instance Profile..." -ForegroundColor Yellow
aws iam remove-role-from-instance-profile --instance-profile-name "$PROJECT-profile" --role-name "$PROJECT-ec2-role" --region $REGION 2>$null
aws iam delete-instance-profile --instance-profile-name "$PROJECT-profile" --region $REGION 2>$null
aws iam detach-role-policy --role-name "$PROJECT-ec2-role" --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess --region $REGION 2>$null
aws iam detach-role-policy --role-name "$PROJECT-ec2-role" --policy-arn arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess --region $REGION 2>$null
aws iam delete-role --role-name "$PROJECT-ec2-role" --region $REGION 2>$null
Write-Host "  IAM eliminado"

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  CLEANUP COMPLETO - Todo eliminado" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Green

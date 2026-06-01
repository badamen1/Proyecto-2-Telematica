<#
.SYNOPSIS
  Monitoreo en tiempo real del proyecto ASG.
  Muestra instancias, carga, eventos de scaling, y logs del controller.

.USAGE
  .\scripts\monitor.ps1                  # Dashboard completo (loop cada 15s)
  .\scripts\monitor.ps1 -Once            # Solo un snapshot
  .\scripts\monitor.ps1 -Logs            # Ver logs en vivo via SSH
#>

param(
    [switch]$Once,
    [switch]$Logs
)

$REGION = "us-east-1"
$PEM_PATH = "$env:USERPROFILE\.ssh\vockey.pem"

function Get-CentralInstance {
    $result = aws ec2 describe-instances `
        --filters "Name=tag:Name,Values=CentralInstance" "Name=instance-state-name,Values=running" `
        --query "Reservations[0].Instances[0].{Id:InstanceId,PublicIp:PublicIpAddress,PrivateIp:PrivateIpAddress}" `
        --output json --region $REGION 2>$null | ConvertFrom-Json
    return $result
}

function Show-Dashboard {
    Clear-Host
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    
    Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║           PROYECTO ASG - MONITOR EN TIEMPO REAL             ║" -ForegroundColor Cyan
    Write-Host "║           $timestamp                            ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""

    # ── Instancia Central ──
    $central = Get-CentralInstance
    if ($central.Id) {
        Write-Host "  [CENTRAL] $($central.Id)" -ForegroundColor Green
        Write-Host "    IP Publica:  $($central.PublicIp)" -ForegroundColor White
        Write-Host "    IP Privada:  $($central.PrivateIp)" -ForegroundColor White
    } else {
        Write-Host "  [CENTRAL] NO ENCONTRADA - ejecuta deploy.ps1" -ForegroundColor Red
        return
    }

    Write-Host ""

    # ── AppInstances ──
    Write-Host "  ┌──────────────────────────────────────────────────────────┐" -ForegroundColor Yellow
    Write-Host "  │  APP INSTANCES (Auto-Scaled)                            │" -ForegroundColor Yellow
    Write-Host "  ├──────────────────────────────────────────────────────────┤" -ForegroundColor Yellow

    $apps = aws ec2 describe-instances `
        --filters "Name=tag:Role,Values=AppInstance" "Name=instance-state-name,Values=running,pending" `
        --query "Reservations[*].Instances[*].{Id:InstanceId,State:State.Name,PrivateIp:PrivateIpAddress,LaunchTime:LaunchTime}" `
        --output json --region $REGION 2>$null | ConvertFrom-Json

    $count = 0
    if ($apps) {
        foreach ($reservation in $apps) {
            foreach ($inst in $reservation) {
                $count++
                $stateColor = if ($inst.State -eq "running") { "Green" } else { "Yellow" }
                $stateIcon = if ($inst.State -eq "running") { "●" } else { "○" }
                Write-Host "  │  $stateIcon $($inst.Id)  $($inst.PrivateIp.PadRight(16))  $($inst.State.PadRight(10))│" -ForegroundColor $stateColor
            }
        }
    }
    if ($count -eq 0) {
        Write-Host "  │  (ninguna AppInstance corriendo todavia)                │" -ForegroundColor DarkGray
    }
    Write-Host "  └──────────────────────────────────────────────────────────┘" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Fleet Size: $count instancias  (min=2, max=5)" -ForegroundColor White

    # ── Target Group Health ──
    Write-Host ""
    Write-Host "  ┌──────────────────────────────────────────────────────────┐" -ForegroundColor Magenta
    Write-Host "  │  TARGET GROUP HEALTH                                    │" -ForegroundColor Magenta
    Write-Host "  ├──────────────────────────────────────────────────────────┤" -ForegroundColor Magenta

    $tgArn = aws elbv2 describe-target-groups --names "proyecto-asg-tg" --query "TargetGroups[0].TargetGroupArn" --output text --region $REGION 2>$null
    if ($tgArn -and $tgArn -ne "None") {
        $health = aws elbv2 describe-target-health --target-group-arn $tgArn --output json --region $REGION 2>$null | ConvertFrom-Json
        if ($health.TargetHealthDescriptions) {
            foreach ($target in $health.TargetHealthDescriptions) {
                $hColor = switch ($target.TargetHealth.State) {
                    "healthy"   { "Green" }
                    "unhealthy" { "Red" }
                    "draining"  { "Yellow" }
                    default     { "DarkGray" }
                }
                $hIcon = switch ($target.TargetHealth.State) {
                    "healthy"   { "✓" }
                    "unhealthy" { "✗" }
                    default     { "?" }
                }
                Write-Host "  │  $hIcon $($target.Target.Id.PadRight(22)) $($target.TargetHealth.State.PadRight(15))     │" -ForegroundColor $hColor
            }
        } else {
            Write-Host "  │  (no hay targets registrados)                          │" -ForegroundColor DarkGray
        }
    }
    Write-Host "  └──────────────────────────────────────────────────────────┘" -ForegroundColor Magenta

    # ── Redis State (via SSH) ──
    Write-Host ""
    if ($central.PublicIp -and (Test-Path $PEM_PATH)) {
        Write-Host "  ┌──────────────────────────────────────────────────────────┐" -ForegroundColor Blue
        Write-Host "  │  REDIS STATE & CONTROLLER LOGS                          │" -ForegroundColor Blue
        Write-Host "  ├──────────────────────────────────────────────────────────┤" -ForegroundColor Blue
        
        $sshCmd = "redis-cli KEYS 'instance:*' 2>/dev/null; echo '---LOGS---'; tail -5 /var/log/controller_asg.log 2>/dev/null || echo 'No controller log yet'"
        $sshOutput = ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i $PEM_PATH ubuntu@$($central.PublicIp) $sshCmd 2>$null
        
        if ($sshOutput) {
            $parts = ($sshOutput -join "`n") -split "---LOGS---"
            $redisKeys = $parts[0].Trim()
            $logs = if ($parts.Count -gt 1) { $parts[1].Trim() } else { "" }
            
            Write-Host "  │  Redis Keys:" -ForegroundColor Blue
            if ($redisKeys) {
                foreach ($line in ($redisKeys -split "`n")) {
                    Write-Host "  │    $line" -ForegroundColor White
                }
            } else {
                Write-Host "  │    (vacio)" -ForegroundColor DarkGray
            }
            Write-Host "  │" -ForegroundColor Blue
            Write-Host "  │  Controller (ultimos logs):" -ForegroundColor Blue
            if ($logs) {
                foreach ($line in ($logs -split "`n" | Select-Object -Last 5)) {
                    $logColor = if ($line -match "Scale-out") { "Green" } 
                                elseif ($line -match "Scale-in") { "Red" }
                                elseif ($line -match "ERROR") { "Red" }
                                else { "White" }
                    Write-Host "  │    $line" -ForegroundColor $logColor
                }
            }
        } else {
            Write-Host "  │  (SSH no disponible aun - User Data puede estar corriendo)" -ForegroundColor DarkGray
        }
        Write-Host "  └──────────────────────────────────────────────────────────┘" -ForegroundColor Blue
    }

    Write-Host ""
    Write-Host "  Ctrl+C para salir" -ForegroundColor DarkGray
    Write-Host ""
}

function Show-LiveLogs {
    $central = Get-CentralInstance
    if (-not $central.PublicIp) {
        Write-Host "No se encontro la instancia central." -ForegroundColor Red
        return
    }
    Write-Host "Conectando a logs en vivo de $($central.PublicIp)..." -ForegroundColor Cyan
    Write-Host "Ctrl+C para salir`n" -ForegroundColor DarkGray
    ssh -o StrictHostKeyChecking=no -i $PEM_PATH ubuntu@$($central.PublicIp) "tail -f /var/log/controller_asg.log /var/log/monitor_s.log"
}

# ── Main ──
if ($Logs) {
    Show-LiveLogs
} elseif ($Once) {
    Show-Dashboard
} else {
    while ($true) {
        Show-Dashboard
        Start-Sleep -Seconds 15
    }
}

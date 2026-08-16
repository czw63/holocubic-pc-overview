param(
    [switch]$KeepRunning,
    [int]$WaitSeconds = 8
)

$ErrorActionPreference = "Continue"
$bridge = Join-Path $PSScriptRoot "pc_bridge.ps1"

$listener = (netstat -ano | findstr :8088 | Select-String 'LISTENING' | ForEach-Object { ($_ -split '\s+')[-1] } | Select-Object -First 1)
if ($listener) {
    Stop-Process -Id ([int]$listener) -Force -ErrorAction SilentlyContinue
}

$pidFile = Join-Path $env:TEMP "spw-pc-overview-metrics.pid"
if (Test-Path -LiteralPath $pidFile) {
    $samplerPid = [int](Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue)
    if ($samplerPid -gt 0) {
        Stop-Process -Id $samplerPid -Force -ErrorAction SilentlyContinue
    }
}

Start-Sleep -Seconds 1

$p = Start-Process -FilePath "powershell.exe" `
    -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $bridge,
        "-ServiceMode",
        "-SaltPluginUrl", "http://127.0.0.1:8091"
    ) `
    -WorkingDirectory $PSScriptRoot `
    -WindowStyle Hidden `
    -RedirectStandardOutput (Join-Path $env:TEMP "pc-overview-bridge-service-mode-out.log") `
    -RedirectStandardError (Join-Path $env:TEMP "pc-overview-bridge-service-mode-err.log") `
    -PassThru

Start-Sleep -Seconds $WaitSeconds
Write-Host "PID:$($p.Id) ALIVE:$(-not $p.HasExited)"
try {
    $health = Invoke-WebRequest -Uri "http://127.0.0.1:8088/health" -UseBasicParsing -TimeoutSec 5
    Write-Host "HEALTH:$($health.Content)"
} catch {
    Write-Host "HEALTH_ERR"
}
try {
    $state = Invoke-WebRequest -Uri "http://127.0.0.1:8088/state" -UseBasicParsing -TimeoutSec 5
    Write-Host "STATE:$($state.Content)"
} catch {
    Write-Host "STATE_ERR"
}
if (-not $KeepRunning) {
    $p.Kill()
    Write-Host "Stopped test process $($p.Id)"
}

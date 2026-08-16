param(
    [string]$StartupName = "HoloCubic PC Overview Bridge",
    [switch]$Unregister
)

$ErrorActionPreference = "Stop"
$dir = $PSScriptRoot
if ([string]::IsNullOrEmpty($dir)) {
    $dir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$bridge = Join-Path $dir "pc_bridge.ps1"
if (-not (Test-Path -LiteralPath $bridge)) {
    Write-Host "pc_bridge.ps1 not found in $dir"
    exit 1
}

$startupDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup"
$vbsPath = Join-Path $startupDir ($StartupName + ".vbs")

if ($Unregister) {
    Remove-Item -LiteralPath $vbsPath -Force -ErrorAction SilentlyContinue
    Write-Host "Removed startup entry $vbsPath"
    exit 0
}

if (-not (Test-Path -LiteralPath $startupDir)) {
    Write-Host "Startup folder not found: $startupDir"
    exit 1
}

$vbs = @"
Set shell = CreateObject("WScript.Shell")
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""$bridge"" -ServiceMode", 0, False
"@
Set-Content -LiteralPath $vbsPath -Value $vbs -Encoding ASCII
Write-Host "Registered logon autostart: $vbsPath"

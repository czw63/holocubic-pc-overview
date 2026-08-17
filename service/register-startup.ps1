param(
    [string]$TaskName = "HoloCubicPCOverviewBridge",
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

$hiddenLauncher = Join-Path $dir "start_bridge_hidden.vbs"
if (-not (Test-Path -LiteralPath $hiddenLauncher)) {
    Write-Host "start_bridge_hidden.vbs not found in $dir"
    exit 1
}

$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$valueName = $TaskName
$runCommand = "wscript.exe //B //Nologo `"$hiddenLauncher`""

if ($Unregister) {
    Remove-ItemProperty -Path $runKey -Name $valueName -ErrorAction SilentlyContinue
    Write-Host "Removed logon startup entry $valueName"
    exit 0
}

New-Item -Path $runKey -Force | Out-Null
New-ItemProperty -Path $runKey -Name $valueName -Value $runCommand -PropertyType String -Force | Out-Null
Write-Host "Registered hidden logon startup entry $valueName"
Write-Host "Action: $runCommand"

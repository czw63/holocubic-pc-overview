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

$arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$bridge`" -ServiceMode"

if ($Unregister) {
    schtasks.exe /Delete /TN $TaskName /F | Out-Null
    Write-Host "Removed scheduled task $TaskName"
    exit 0
}

$service = New-Object -ComObject Schedule.Service
$service.Connect()
$folder = $service.GetFolder("\")
$task = $service.NewTask(0)
$task.RegistrationInfo.Description = "HoloCubic PC Overview bridge service mode"
$task.Settings.StartWhenAvailable = $true
$task.Settings.DisallowStartIfOnBatteries = $false
$task.Settings.StopIfGoingOnBatteries = $false
$task.Settings.ExecutionTimeLimit = "PT0S"
$trigger = $task.Triggers.Create(9)
$trigger.UserId = "$env:USERDOMAIN\$env:USERNAME"
$action = $task.Actions.Create(0)
$action.Path = "powershell.exe"
$action.Arguments = $arguments
$action.WorkingDirectory = $dir
$folder.RegisterTaskDefinition($TaskName, $task, 6, $null, $null, 3) | Out-Null
Write-Host "Registered logon autostart task $TaskName"
Write-Host "Action: powershell.exe $arguments"

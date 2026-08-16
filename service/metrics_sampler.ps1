param(
    [string]$OutputFile = "",
    [string]$StopFile = "",
    [int]$BridgePid = 0
)

$ErrorActionPreference = "SilentlyContinue"
if (-not $OutputFile) { $OutputFile = Join-Path $env:TEMP "spw-pc-overview-metrics.txt" }
if (-not $StopFile) { $StopFile = Join-Path $env:TEMP "spw-pc-overview-metrics.stop" }

$lastCpu = $null
$lastGpu = $null
$lastParentCheck = 0
while (-not (Test-Path -LiteralPath $StopFile)) {
    if ($BridgePid -gt 0) {
        $nowMs = [Environment]::TickCount
        if ($nowMs - $lastParentCheck -gt 5000) {
            $lastParentCheck = $nowMs
            if (-not (Get-Process -Id $BridgePid -ErrorAction SilentlyContinue)) {
                break
            }
        }
    }
    $started = [DateTime]::UtcNow
    try {
        $samples = Get-Counter `
            "\Processor(_Total)\% Processor Time", `
            "\GPU Engine(*)\Utilization Percentage" `
            -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop
        $cpuFound = $false
        $gpuFound = $false
        $gpuSum = 0.0
        foreach ($sample in $samples.CounterSamples) {
            $path = [string]$sample.Path
            if (-not $cpuFound -and $path -like "*Processor(_Total)*") {
                $lastCpu = [double]$sample.CookedValue
                $cpuFound = $true
            } elseif ($path -like "*GPU Engine*") {
                $gpuSum += [double]$sample.CookedValue
                $gpuFound = $true
            }
        }
        if ($gpuSum -gt 100) { $gpuSum = 100 }
        if ($gpuFound) { $lastGpu = $gpuSum }
    } catch {
        try {
            $cpuSample = (Get-Counter "\Processor(_Total)\% Processor Time" `
                -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop).CounterSamples[0]
            $lastCpu = [double]$cpuSample.CookedValue
        } catch {
        }
    }
    if ($null -ne $lastCpu -or $null -ne $lastGpu) {
        $line = "cpu=" + [string]($(if ($null -ne $lastCpu) { $lastCpu } else { "" })) +
            " gpu=" + [string]($(if ($null -ne $lastGpu) { $lastGpu } else { "" })) +
            " ts=" + [string]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
        try { Set-Content -LiteralPath $OutputFile -Value $line -Encoding ASCII } catch {
        }
    }
    $elapsed = ([DateTime]::UtcNow - $started).TotalMilliseconds
    if ($elapsed -lt 900) {
        Start-Sleep -Milliseconds ([int](900 - $elapsed))
    }
}

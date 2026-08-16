param(
    [string]$OutputFile = "",
    [string]$StopFile = ""
)

$ErrorActionPreference = "SilentlyContinue"
if (-not $OutputFile) { $OutputFile = Join-Path $env:TEMP "spw-pc-overview-metrics.txt" }
if (-not $StopFile) { $StopFile = Join-Path $env:TEMP "spw-pc-overview-metrics.stop" }

$lastCpu = $null
$lastGpu = $null
while (-not (Test-Path -LiteralPath $StopFile)) {
    $started = [DateTime]::UtcNow
    try {
        $samples = Get-Counter `
            "\Processor(_Total)\% Processor Time", `
            "\GPU Engine(*)\Utilization Percentage" `
            -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop
        $cpuSample = $samples.CounterSamples |
            Where-Object { $_.Path -like "*Processor(_Total)*" } |
            Select-Object -First 1
        if ($cpuSample) { $lastCpu = [double]$cpuSample.CookedValue }
        $gpuSamples = $samples.CounterSamples |
            Where-Object { $_.Path -like "*GPU Engine*" }
        if ($gpuSamples) {
            $gpu = [double](($gpuSamples | Measure-Object -Property CookedValue -Sum).Sum)
            if ($gpu -gt 100) { $gpu = 100 }
            $lastGpu = $gpu
        }
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

param(
    [int]$Port = 8088,
    [int]$UdpPort = 8090,
    [int]$CoverSize = 96,
    [int]$SpectrumProcessId = 0,
    [string]$SpectrumProcessName = "",
    [string]$SaltPluginUrl = "",
    [switch]$ServiceMode,
    [switch]$SmtcFallback,
    [switch]$NoSpectrum,
    [switch]$SelfTest
)

# Requires Windows PowerShell 5.1 for the built-in WinRT projection used by SMTC.
if ($PSVersionTable.PSEdition -ne "Desktop") {
    Write-Host "Run this script with powershell.exe (Windows PowerShell 5.1), not pwsh."
    exit 1
}

$ErrorActionPreference = "Stop"
$script:Dir = $PSScriptRoot
if ([string]::IsNullOrEmpty($script:Dir)) {
    $script:Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
Set-Location -LiteralPath $script:Dir
$env:PATH = $script:Dir + ";" + $env:PATH
try {
    [Environment]::CurrentDirectory = $script:Dir
} catch {
}

Add-Type -AssemblyName System.Runtime.WindowsRuntime

$audioPath = Join-Path $script:Dir "audio_capture.cs"
$serverPath = Join-Path $script:Dir "bridge_server.cs"
if (-not (Test-Path -LiteralPath $audioPath) -or -not (Test-Path -LiteralPath $serverPath)) {
    Write-Host "bridge_server.cs / audio_capture.cs not found next to pc_bridge.ps1"
    exit 1
}

try {
    $audioSource = [System.IO.File]::ReadAllText($audioPath)
    $serverSource = [System.IO.File]::ReadAllText($serverPath)
    Add-Type -TypeDefinition ($audioSource + "`n" + $serverSource) `
        -ReferencedAssemblies "System.Drawing"
} catch {
    Write-Host ("C# compile failed: " + $_.Exception.Message)
    exit 1
}

$null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType=WindowsRuntime]
$null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties, Windows.Media.Control, ContentType=WindowsRuntime]
$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType=WindowsRuntime]
$null = [Windows.Storage.FileProperties.ThumbnailMode, Windows.Storage.FileProperties, ContentType=WindowsRuntime]
$null = [Windows.Storage.FileProperties.ThumbnailOptions, Windows.Storage.FileProperties, ContentType=WindowsRuntime]

$asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq "AsTask" -and $_.IsGenericMethod -and
        $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
})[0]

function Await($operation, $resultType) {
    $task = $asTask.MakeGenericMethod($resultType).Invoke($null, @($operation))
    [void]$task.Wait(6000)
    return $task.Result
}

$server = New-Object -TypeName PcBridgeServer.BridgeServer -ArgumentList $Port
$script:SaltMediaEvent = New-Object System.Threading.AutoResetEvent($false)
try {
    $server.Start()
    $server.SaltMediaChanged = [Action]{ [void]$script:SaltMediaEvent.Set() }
} catch {
    Write-Host ("Could not start bridge on port " + $Port + ": " + $_.Exception.Message)
    exit 1
}

if ($ServiceMode -and -not $SaltPluginUrl) {
    $envPlugin = [Environment]::GetEnvironmentVariable("PC_OVERVIEW_SALT_PLUGIN_URL")
    if (-not [string]::IsNullOrEmpty($envPlugin)) {
        $SaltPluginUrl = $envPlugin
    } else {
        $SaltPluginUrl = "http://127.0.0.1:8091"
    }
}
$script:SaltPluginUrl = $SaltPluginUrl

function Test-SaltPlayerRunning {
    try {
        return @(Get-Process -Name "Salt Player for Windows" -ErrorAction Stop).Count -gt 0
    } catch {
        return $false
    }
}

$script:ServiceMode = [bool]$ServiceMode
$script:SmtcFallback = [bool]$SmtcFallback
$script:SpectrumEnabled = -not $NoSpectrum
$script:SaltPlayerAvailable = [ref](Test-SaltPlayerRunning)
$script:SpwWatchThread = $null

if ($script:SpectrumEnabled) {
    if (-not $script:ServiceMode) {
        if ($SpectrumProcessId -le 0 -and [string]::IsNullOrEmpty($SpectrumProcessName)) {
            $spw = Get-Process -Name "Salt Player for Windows" -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($spw) {
                $SpectrumProcessName = "Salt Player for Windows"
                Write-Host "Auto-detected Salt Player for Windows; capturing only that process."
            }
        }
    } elseif (-not $script:SaltPlayerAvailable.Value) {
        Write-Host "Service mode: spectrum will start when Salt Player for Windows is running."
    }
    if ($script:ServiceMode -and -not $script:SaltPlayerAvailable.Value) {
        # Spectrum starts later from the SPW watchdog thread.
    } else {
        try {
            $server.StartSpectrum($UdpPort, $SpectrumProcessId, $SpectrumProcessName)
            Write-Host "Loopback spectrum capture started."
        } catch {
            Write-Host ("Spectrum disabled: " + $_.Exception.Message)
        }
    }
}

if ($script:ServiceMode) {
    $watchScript = {
        param(
            [int]$UdpPort,
            [PcBridgeServer.BridgeServer]$BridgeServer,
            [System.Threading.AutoResetEvent]$WakeEvent,
            [ref]$Available,
            [string]$PluginUrl,
            [bool]$SpectrumEnabled
        )
        $ErrorActionPreference = "SilentlyContinue"
        $debugPath = Join-Path $env:TEMP "spw-pc-overview-bridge-debug.log"
        $debugWrite = {
            param($message)
            Add-Content -LiteralPath $debugPath -Value (
                (Get-Date -Format "HH:mm:ss.fff") + " " + $message) -Encoding UTF8
        }
        $wasAvailable = [bool]$Available.Value
        while ($true) {
            $available = @(Get-Process -Name "Salt Player for Windows" -ErrorAction SilentlyContinue).Count -gt 0
            if ($available -and $PluginUrl) {
                try {
                    $client = New-Object System.Net.WebClient
                    try {
                        $data = $client.DownloadString($PluginUrl + "/api/media")
                        $available = [bool]$data
                    } finally {
                        $client.Dispose()
                    }
                } catch {
                    $available = $false
                }
            }
            if ($available -ne $wasAvailable) {
                $wasAvailable = $available
                try {
                    if ($available -and $SpectrumEnabled) {
                        $BridgeServer.StartSpectrum($UdpPort, 0, "Salt Player for Windows")
                        & $debugWrite "spw watchdog: spectrum started"
                    } elseif (-not $available) {
                        $BridgeServer.Stop()
                        & $debugWrite "spw watchdog: spectrum stopped"
                    }
                } catch {
                    & $debugWrite ("spw watchdog error: " + $_.Exception.Message)
                }
                try {
                    $Available.Value = $available
                    $WakeEvent.Set()
                } catch {
                }
            }
            Start-Sleep -Milliseconds 1000
        }
    }
    $watchRunspace = [runspacefactory]::CreateRunspace()
    $watchRunspace.Open()
    $watchPowerShell = [powershell]::Create()
    $watchPowerShell.Runspace = $watchRunspace
    $null = $watchPowerShell.AddScript($watchScript)
    $null = $watchPowerShell.AddArgument([int]$UdpPort)
    $null = $watchPowerShell.AddArgument($server)
    $null = $watchPowerShell.AddArgument($script:SaltMediaEvent)
    $null = $watchPowerShell.AddArgument($script:SaltPlayerAvailable)
    $null = $watchPowerShell.AddArgument([string]$SaltPluginUrl)
    $null = $watchPowerShell.AddArgument($script:SpectrumEnabled)
    $script:SpwWatchThread = $watchPowerShell
    $null = $watchPowerShell.BeginInvoke()
    Write-Host "SPW watchdog started (service mode)."
}

$script:State = @{
    type = "state"
    ts = 0
    cpu = 0
    gpu = 0
    mem = 0
    mem_used = $null
    mem_total = $null
    playing = $false
    status = "NoSession"
    title = ""
    artist = ""
    album = ""
    app = ""
    cover_version = 0
    cover_ready = $true
    cover_error = ""
}

$script:LastMediaKey = ""
$script:CoverVersion = 0
$script:CoverDirty = $false
$script:MediaPath = ""
$script:LastError = ""
$script:LastPrint = 0
$script:LastMetricsMs = 0
$script:LastStateKey = ""
$script:LastStateSentMs = 0
$script:CoverError = ""
$script:MetricsFile = Join-Path $env:TEMP "spw-pc-overview-metrics.txt"
$script:MetricsStopFile = Join-Path $env:TEMP "spw-pc-overview-metrics.stop"
$script:MetricsPidFile = Join-Path $env:TEMP "spw-pc-overview-metrics.pid"
$script:Metrics = $null
try {
    $script:Metrics = New-Object PcBridgeServer.FastMetrics
} catch {
    $script:Metrics = $null
}
$script:MetricsSampler = $null

function Write-BridgeDebug($message) {
    try {
        $debugPath = Join-Path $env:TEMP "spw-pc-overview-bridge-debug.log"
        Add-Content -LiteralPath $debugPath -Value (
            (Get-Date -Format "HH:mm:ss.fff") + " " + $message) -Encoding UTF8
    } catch {
    }
}

function Get-MemoryUsage {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $total = [double]$os.TotalVisibleMemorySize
        $free = [double]$os.FreePhysicalMemory
        if ($total -le 0) { return @{ pct = $null; used = $null; total = $null } }
        $used = $total - $free
        return @{
            pct = [double]($used / $total * 100.0)
            used = [double]($used / 1024.0 / 1024.0)
            total = [double]($total / 1024.0 / 1024.0)
        }
    } catch {
        Write-BridgeDebug ("memory probe failed: " + $_.Exception.Message)
        return @{ pct = $null; used = $null; total = $null }
    }
}

function Get-MediaSnapshot {
    try {
        $op = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()
        $mgr = Await $op ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
        $session = $null
        try { $session = $mgr.GetCurrentSession() } catch { $session = $null }
        if (-not $session) {
            try {
                $sessions = $mgr.GetSessions()
                foreach ($candidate in $sessions) {
                    if ($candidate.SourceAppUserModelId) {
                        $session = $candidate
                        break
                    }
                }
            } catch { $session = $null }
        }
        if (-not $session) { return $null }

        $propsOp = $session.TryGetMediaPropertiesAsync()
        $props = Await $propsOp ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
        $status = "Stopped"
        try {
            $status = $session.GetPlaybackInfo().PlaybackStatus.ToString()
        } catch { }

        return @{
            app = [string]$session.SourceAppUserModelId
            title = [string]$props.Title
            artist = [string]$props.Artist
            album = [string]$props.AlbumTitle
            status = [string]$status
            thumbnail = $props.Thumbnail
        }
    } catch {
        $script:LastError = $_.Exception.Message
        return $null
    }
}

function Get-CoverRgb565($thumbnail) {
    if (-not $thumbnail) { return $null }
    try {
        $streamType = [Type]::GetType(
            "Windows.Storage.Streams.IRandomAccessStreamWithContentType,Windows.Storage.Streams,ContentType=WindowsRuntime")
        if (-not $streamType) {
            $streamType = [Type]::GetType(
                "Windows.Storage.Streams.IRandomAccessStream,Windows.Storage.Streams,ContentType=WindowsRuntime")
        }
        $op = $thumbnail.OpenReadAsync()
        $stream = Await $op $streamType
        $asStreamMethod = ([System.IO.WindowsRuntimeStreamExtensions].GetMethods() |
            Where-Object { $_.Name -eq "AsStream" -and $_.GetParameters().Count -eq 1 })[0]
        $netStream = $asStreamMethod.Invoke($null, @($stream))
        $ms = New-Object System.IO.MemoryStream
        $netStream.CopyTo($ms)
        $bytes = $ms.ToArray()
        $netStream.Dispose()
        $ms.Dispose()
        if ($bytes.Length -lt 16) { return $null }

        Add-Type -AssemblyName System.Drawing
        $srcStream = New-Object System.IO.MemoryStream (,$bytes)
        $srcBmp = New-Object System.Drawing.Bitmap $srcStream
        $bmp = New-Object System.Drawing.Bitmap $CoverSize, $CoverSize
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear([System.Drawing.Color]::Black)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.DrawImage($srcBmp, 0, 0, $CoverSize, $CoverSize)

        $rgb = New-Object byte[] ($CoverSize * $CoverSize * 2)
        for ($y = 0; $y -lt $CoverSize; $y++) {
            for ($x = 0; $x -lt $CoverSize; $x++) {
                $c = $bmp.GetPixel($x, $y)
                $v = (($c.R -band 0xF8) -shl 8) -bor (($c.G -band 0xFC) -shl 3) -bor ($c.B -shr 3)
                $idx = ($y * $CoverSize + $x) * 2
                $rgb[$idx] = [byte]($v -band 0xFF)
                $rgb[$idx + 1] = [byte](($v -shr 8) -band 0xFF)
            }
        }

        $g.Dispose()
        $bmp.Dispose()
        $srcBmp.Dispose()
        $srcStream.Dispose()
        return ,$rgb
    } catch {
        $script:LastError = $_.Exception.Message
        return $null
    }
}

function Get-ThumbnailBytes($thumbnail) {
    if (-not $thumbnail) { return $null }
    try {
        $streamType = [Type]::GetType(
            "Windows.Storage.Streams.IRandomAccessStreamWithContentType,Windows.Storage.Streams,ContentType=WindowsRuntime")
        if (-not $streamType) {
            $streamType = [Type]::GetType(
                "Windows.Storage.Streams.IRandomAccessStream,Windows.Storage.Streams,ContentType=WindowsRuntime")
        }
        $op = $thumbnail.OpenReadAsync()
        $stream = Await $op $streamType
        $asStreamMethod = ([System.IO.WindowsRuntimeStreamExtensions].GetMethods() |
            Where-Object { $_.Name -eq "AsStream" -and $_.GetParameters().Count -eq 1 })[0]
        $netStream = $asStreamMethod.Invoke($null, @($stream))
        $ms = New-Object System.IO.MemoryStream
        $netStream.CopyTo($ms)
        $bytes = $ms.ToArray()
        $netStream.Dispose()
        $ms.Dispose()
        if ($bytes.Length -lt 16) { return $null }
        return ,$bytes
    } catch {
        $script:LastError = $_.Exception.Message
        return $null
    }
}

function Get-CoverRgb565FromFile($path) {
    if (-not $path -or -not (Test-Path -LiteralPath $path)) {
        $script:CoverError = "cover file not found: $path"
        return $null
    }
    try {
        $fileOp = [Windows.Storage.StorageFile]::GetFileFromPathAsync($path)
        $file = Await $fileOp ([Windows.Storage.StorageFile])
        $thumbOp = $file.GetThumbnailAsync(
            [Windows.Storage.FileProperties.ThumbnailMode]::MusicView,
            512,
            [Windows.Storage.FileProperties.ThumbnailOptions]::None)
        $thumbType = [Type]::GetType(
            "Windows.Storage.Streams.IRandomAccessStreamWithContentType,Windows.Storage.Streams,ContentType=WindowsRuntime")
        $thumb = Await $thumbOp $thumbType
        $bytes = Get-ThumbnailBytes $thumb
        if ($bytes) {
            $script:CoverError = ""
            return ,$bytes
        }
        $script:CoverError = "WinRT thumbnail returned no bytes"
        return $null
    } catch {
        $script:CoverError = $_.Exception.Message
        $script:LastError = $_.Exception.Message
        return $null
    }
}

function Get-CoverBytesFromFile($path) {
    if (-not $path -or -not (Test-Path -LiteralPath $path)) {
        $script:CoverError = "cover file not found: $path"
        return $null
    }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "ffmpeg.exe"
        $psi.Arguments = "-hide_banner -loglevel error -y -i `"$path`" -map 0:v:0 -c:v mjpeg -frames:v 1 -f image2pipe -"
        $psi.RedirectStandardOutput = $true
        $psi.UseShellExecute = $false
        $p = [System.Diagnostics.Process]::Start($psi)
        $ms = New-Object System.IO.MemoryStream
        try {
            $p.StandardOutput.BaseStream.CopyTo($ms)
        } finally {
            [void]$p.WaitForExit(10000)
            $p.Dispose()
        }
        if ($ms.Length -gt 16) {
            $script:CoverError = ""
            return ,$ms.ToArray()
        }
        $script:CoverError = "ffmpeg produced no cover stream"
        return $null
    } catch {
        $script:CoverError = $_.Exception.Message
        $script:LastError = $_.Exception.Message
        return $null
    }
}

function Get-CoverBytesFromPlugin {
    if (-not $script:SaltPluginUrl) { return $null }
    try {
        $client = New-Object System.Net.WebClient
        try {
            $bytes = $client.DownloadData($script:SaltPluginUrl + "/api/cover")
            if ($bytes -and $bytes.Length -gt 16) {
                $script:CoverError = ""
                return ,$bytes
            }
        } finally {
            $client.Dispose()
        }
        $script:CoverError = "plugin cover empty"
        return $null
    } catch {
        $script:CoverError = "plugin cover failed: " + $_.Exception.Message
        return $null
    }
}

function Get-SaltPluginMedia {
    if (-not $script:SaltPluginUrl) { return $null }
    try {
        $media = Invoke-RestMethod -Uri ($script:SaltPluginUrl + "/api/media") -TimeoutSec 2
        if (-not $media -or $media.ok -ne $true) { return $null }
        $playing = $false
        if ($null -ne $media.playing) { $playing = [bool]$media.playing }
        $state = [string]$media.state
        if ($playing) {
            $state = "Playing"
        } elseif ($state -eq "") {
            $state = "Paused"
        }
        return @{
            title = [string]$media.title
            artist = [string]$media.artist
            album = [string]$media.album
            path = [string]$media.path
            playing = $playing
            status = $state
            app = "Salt Player for Windows"
        }
    } catch {
        $script:LastError = $_.Exception.Message
        return $null
    }
}

if ($SelfTest) {
    try {
        $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType=WindowsRuntime]
        $null = [Windows.Storage.Streams.RandomAccessStreamReference, Windows.Storage.Streams, ContentType=WindowsRuntime]
        $pngPath = (Resolve-Path (Join-Path $script:Dir "..\package\main.png")).Path
        $fileOp = [Windows.Storage.StorageFile]::GetFileFromPathAsync($pngPath)
        $file = Await $fileOp ([Windows.Storage.StorageFile])
        $ref = [Windows.Storage.Streams.RandomAccessStreamReference]::CreateFromFile($file)
        $rgb = Get-CoverRgb565 $ref
        if ($rgb -and $rgb.Length -eq ($CoverSize * $CoverSize * 2)) {
            Write-Host ("SELFTEST_OK " + $rgb.Length)
            exit 0
        }
        Write-Host "SELFTEST_FAIL"
        exit 1
    } catch {
        Write-Host ("SELFTEST_ERR " + $_.Exception.ToString())
        exit 1
    }
}

function Start-MetricsSampler {
    if ($script:Metrics) { return }
    if ($script:MetricsSampler -and -not $script:MetricsSampler.HasExited) { return }
    try {
        $oldPid = 0
        if (Test-Path -LiteralPath $script:MetricsPidFile) {
            $oldPid = [int](Get-Content -LiteralPath $script:MetricsPidFile -Raw -ErrorAction Stop)
        }
        if ($oldPid -gt 0 -and $oldPid -ne $PID) {
            Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $script:MetricsStopFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:MetricsFile -Force -ErrorAction SilentlyContinue
        $samplerPath = Join-Path $script:Dir "metrics_sampler.ps1"
        if (-not (Test-Path -LiteralPath $samplerPath)) { return }
        $script:MetricsSampler = Start-Process -FilePath "powershell.exe" `
            -ArgumentList @(
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-File", $samplerPath,
                "-OutputFile", $script:MetricsFile,
                "-StopFile", $script:MetricsStopFile
            ) -WindowStyle Hidden -PassThru
        Set-Content -LiteralPath $script:MetricsPidFile -Value ([string]$script:MetricsSampler.Id) -Encoding ASCII
    } catch {
        $script:MetricsSampler = $null
    }
}

function Read-MetricsFile {
    try {
        if (-not (Test-Path -LiteralPath $script:MetricsFile)) { return $null }
        $age = (Get-Date) - (Get-Item -LiteralPath $script:MetricsFile).LastWriteTime
        if ($age.TotalSeconds -gt 5) { return $null }
        $line = Get-Content -LiteralPath $script:MetricsFile -Raw -ErrorAction Stop
        $values = @{}
        foreach ($token in ($line -split "\s+")) {
            $pair = $token -split "=", 2
            if ($pair.Count -eq 2 -and $pair[1] -ne "") {
                $values[$pair[0]] = [double]$pair[1]
            }
        }
        return $values
    } catch {
        return $null
    }
}

function Update-SystemMetrics {
    Start-MetricsSampler
    if ($script:Metrics) {
        try {
            $cpu = $script:Metrics.CpuPercent()
            if (-not [double]::IsNaN($cpu)) {
                $script:State.cpu = [math]::Round($cpu)
            }
        } catch {
        }
        try {
            $gpu = $script:Metrics.GpuPercent()
            if (-not [double]::IsNaN($gpu)) {
                $script:State.gpu = [math]::Round($gpu)
            }
        } catch {
        }
    } else {
        $sampled = Read-MetricsFile
        if ($sampled) {
            if ($sampled.ContainsKey("cpu")) {
                $script:State.cpu = [math]::Round($sampled["cpu"])
            }
            if ($sampled.ContainsKey("gpu")) {
                $script:State.gpu = [math]::Round($sampled["gpu"])
            }
        }
    }
    $mem = Get-MemoryUsage
    if ($null -ne $mem.pct) {
        $script:State.mem = [math]::Round($mem.pct)
        $script:State.mem_used = [math]::Round($mem.used, 1)
        $script:State.mem_total = [math]::Round($mem.total, 1)
    }
}

function Update-Media {
    $updateSw = [System.Diagnostics.Stopwatch]::StartNew()
    $media = $null
    if ($script:ServiceMode -and -not $script:SaltPlayerAvailable.Value) {
        Write-BridgeDebug "service mode: salt player not running"
        $media = $null
    } elseif ($script:SaltPluginUrl) {
        $media = Get-SaltPluginMedia
        if (-not $media -and ($script:SmtcFallback -or -not $script:ServiceMode)) {
            $media = Get-MediaSnapshot
        }
    } elseif (-not $script:ServiceMode) {
        $media = Get-MediaSnapshot
    }
    if ($media) {
        $key = $media.title + "|" + $media.artist + "|" + $media.album + "|" + $media.path
        if ($key -ne $script:LastMediaKey) {
            $script:LastMediaKey = $key
            $script:CoverVersion++
            $script:CoverDirty = $true
            $script:MediaPath = [string]$media.path
            $script:State.cover_ready = $false
            Write-BridgeDebug ("media change title=" + $media.title + " artist=" + $media.artist)
        }
        $script:State.title = $media.title
        $script:State.artist = $media.artist
        $script:State.album = $media.album
        $script:State.app = if ($media.app) { $media.app } else { "" }
        $script:State.status = if ($media.status) { $media.status } else { "NoSession" }
        $script:State.playing = if ($null -ne $media.playing) {
            [bool]$media.playing
        } else {
            $media.status -match "Playing"
        }
        $updateSw.Stop()
        Write-BridgeDebug ("update_ms=" + $updateSw.ElapsedMilliseconds + " title=" + $media.title)
    } else {
        if ($script:LastMediaKey -ne "") {
            $script:LastMediaKey = ""
            $script:CoverVersion++
            $script:CoverDirty = $true
            $script:MediaPath = ""
            $script:State.cover_ready = $false
        }
        $script:State.title = ""
        $script:State.artist = ""
        $script:State.album = ""
        $script:State.app = ""
        $script:State.status = "NoSession"
        $script:State.playing = $false
    }
    $script:State.cover_version = $script:CoverVersion
}

function Resolve-Cover {
    if (-not $script:CoverDirty) { return }
    $script:CoverDirty = $false
    $coverSw = [System.Diagnostics.Stopwatch]::StartNew()
    $cover = $null
    $path = $script:MediaPath
    if ($path) {
        $cover = Get-CoverBytesFromPlugin
        if (-not $cover) {
            $cover = Get-CoverBytesFromFile $path
        }
        if (-not $cover) {
            $cover = Get-CoverRgb565FromFile $path
        }
    }
    if (-not $cover) {
        $snap = Get-MediaSnapshot
        if ($snap -and $snap.thumbnail) {
            $cover = Get-ThumbnailBytes $snap.thumbnail
        }
    }
    if ($cover) {
        try {
            $server.SetCoverJpeg($cover, ([string]$script:CoverVersion), $CoverSize)
            $script:State.cover_error = ""
        } catch {
            $script:State.cover_error = "SetCoverJpeg failed: " + $_.Exception.Message
            $server.SetCover($null, ([string]$script:CoverVersion))
        }
    } else {
        $script:State.cover_error = $script:CoverError
        $server.SetCover($null, ([string]$script:CoverVersion))
    }
    $script:State.cover_ready = $true
    $coverSw.Stop()
    Write-BridgeDebug ("cover_ms=" + $coverSw.ElapsedMilliseconds +
        " ok=" + [bool]$cover + " path=" + $path)
}

function Push-State {
    $now = [Environment]::TickCount
    $stateKey = [string]::Join("|", @(
        [string]$script:State.title,
        [string]$script:State.artist,
        [string]$script:State.album,
        [string]$script:State.app,
        [string]$script:State.status,
        [string]$script:State.playing,
        [string]$script:State.cover_version,
        [string]$script:State.cover_ready,
        [string]$script:State.cpu,
        [string]$script:State.gpu,
        [string]$script:State.mem,
        [string]$script:State.mem_used,
        [string]$script:State.mem_total
    ))
    if ($stateKey -ne $script:LastStateKey -or
        ($now - $script:LastStateSentMs -gt 1000)) {
        $script:LastStateKey = $stateKey
        $script:LastStateSentMs = $now
        $script:State.ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $json = $script:State | ConvertTo-Json -Compress -Depth 4
        $server.SetState($json)
    }
}

Write-Host ("PC Overview bridge listening on 0.0.0.0:" + $Port)
Write-Host "Open http://localhost:$Port/ to verify."

try {
    while ($true) {
        try {
            Update-Media
            Push-State
            if ($script:CoverDirty) {
                Resolve-Cover
            }
            $now = [Environment]::TickCount
            if ($script:LastMetricsMs -eq 0 -or ($now - $script:LastMetricsMs -gt 1000)) {
                Update-SystemMetrics
                $script:LastMetricsMs = $now
            }
            Push-State

            if ($now - $script:LastPrint -gt 10000) {
                $script:LastPrint = $now
                Write-Host ("clients=" + $server.ClientCount +
                    " audio=" + $server.AudioRunning +
                    " cpu=" + $script:State.cpu +
                    " gpu=" + $script:State.gpu +
                    " mem=" + $script:State.mem +
                    " media=" + $script:State.status)
                if ($script:LastError) {
                    Write-Host ("last error: " + $script:LastError)
                    $script:LastError = ""
                }
            }
        } catch {
            Write-Host ("poll error: " + $_.Exception.Message)
        }
        $woke = $script:SaltMediaEvent.WaitOne(100)
        if ($woke) {
            Write-BridgeDebug "event wake"
        }
    }
} finally {
    try {
        if ($script:MetricsSampler -and -not $script:MetricsSampler.HasExited) {
            $script:MetricsSampler.Kill()
            $script:MetricsSampler.WaitForExit(2000)
        }
    } catch {
    }
    $server.Stop()
}

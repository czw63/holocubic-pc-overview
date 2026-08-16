$ErrorActionPreference = "Stop"

$root = $PSScriptRoot
$src = Join-Path $root "src"
$stubs = Join-Path $root "stubs"
$build = Join-Path $root "build"
$classes = Join-Path $build "classes"
$rootDir = Join-Path $build "root"
$pluginVersion = "0.1.0"
$pluginZip = Join-Path $build "plugin-SPWPCOverview-$pluginVersion.zip"

if (Test-Path -LiteralPath $build) {
    Remove-Item -LiteralPath $build -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $classes | Out-Null
New-Item -ItemType Directory -Force -Path $rootDir | Out-Null

$sources = @()
$sources += Get-ChildItem -Path $stubs -Recurse -Filter "*.java" | ForEach-Object { $_.FullName }
$sources += Get-ChildItem -Path $src -Recurse -Filter "*.java" | ForEach-Object { $_.FullName }

javac -encoding UTF-8 -d $classes $sources
if ($LASTEXITCODE -ne 0) {
    throw "javac failed"
}

$idxDir = Join-Path $classes "META-INF"
New-Item -ItemType Directory -Force -Path $idxDir | Out-Null
Copy-Item -LiteralPath (Join-Path $src "META-INF\extensions.idx") -Destination (Join-Path $idxDir "extensions.idx") -Force

$manifest = @"
Manifest-Version: 1.0
Plugin-Class: com.czw.pcoverview.spw.SpwPcOverviewPlugin
Plugin-Id: SPWPCOverview
Plugin-Name: SPW PC Overview
Plugin-Version: $pluginVersion
Plugin-Provider: czw63
Plugin-Description: Exposes current track metadata, file path and playback state as HTTP API
Plugin-Open-Source-Url: https://github.com/czw63/holocubic-pc-overview
Plugin-Has-Config: false

"@
$manifestPath = Join-Path $idxDir "MANIFEST.MF"
Set-Content -LiteralPath $manifestPath -Value $manifest -Encoding Ascii

$rootMeta = Join-Path $rootDir "META-INF"
New-Item -ItemType Directory -Force -Path $rootMeta | Out-Null
$rootManifest = @"
Manifest-Version: 1.0

"@
Set-Content -LiteralPath (Join-Path $rootMeta "MANIFEST.MF") -Value $rootManifest -Encoding Ascii

$rootClasses = Join-Path $rootDir "classes"
New-Item -ItemType Directory -Force -Path $rootClasses | Out-Null
$rootPackage = Join-Path $rootClasses "com\czw"
New-Item -ItemType Directory -Force -Path $rootPackage | Out-Null
Copy-Item -Path (Join-Path $classes "com\czw\*") -Destination $rootPackage -Recurse -Force

$rootClassesMeta = Join-Path $rootClasses "META-INF"
New-Item -ItemType Directory -Force -Path $rootClassesMeta | Out-Null
Copy-Item -LiteralPath (Join-Path $idxDir "extensions.idx") -Destination (Join-Path $rootClassesMeta "extensions.idx") -Force
Copy-Item -LiteralPath (Join-Path $idxDir "MANIFEST.MF") -Destination (Join-Path $rootClassesMeta "MANIFEST.MF") -Force

$rootLib = Join-Path $rootDir "lib"
New-Item -ItemType Directory -Force -Path $rootLib | Out-Null
Set-Content -LiteralPath (Join-Path $rootLib ".keep") -Value "" -Encoding Ascii

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Add-ZipFile {
    param(
        [System.IO.Compression.ZipArchive]$Archive,
        [string]$EntryName,
        [string]$SourcePath
    )
    $entry = $Archive.CreateEntry($EntryName, [System.IO.Compression.CompressionLevel]::Optimal)
    $entryStream = $entry.Open()
    $sourceStream = [System.IO.File]::OpenRead($SourcePath)
    try {
        $sourceStream.CopyTo($entryStream)
    } finally {
        $sourceStream.Dispose()
        $entryStream.Dispose()
    }
}

function Add-ZipTree {
    param(
        [System.IO.Compression.ZipArchive]$Archive,
        [string]$Directory,
        [string]$Prefix
    )
    foreach ($item in Get-ChildItem -LiteralPath $Directory) {
        if ($item.PSIsContainer) {
            $name = $Prefix + $item.Name + "/"
            $null = $Archive.CreateEntry($name)
            Add-ZipTree -Archive $Archive -Directory $item.FullName -Prefix $name
        } else {
            Add-ZipFile -Archive $Archive -EntryName ($Prefix + $item.Name) -SourcePath $item.FullName
        }
    }
}

$zipStream = [System.IO.File]::Create($pluginZip)
$archive = New-Object System.IO.Compression.ZipArchive($zipStream, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    Add-ZipTree -Archive $archive -Directory $rootDir -Prefix ""
} finally {
    $archive.Dispose()
    $zipStream.Dispose()
}

Write-Host "Built $pluginZip"

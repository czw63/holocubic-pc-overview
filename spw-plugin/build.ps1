$ErrorActionPreference = "Stop"

$root = $PSScriptRoot
$src = Join-Path $root "src"
$stubs = Join-Path $root "stubs"
$build = Join-Path $root "build"
$classes = Join-Path $build "classes"
$dist = Join-Path $build "dist"
$pluginJar = Join-Path $build "spw-pc-overview-plugin.jar"
$pluginVersion = "0.1.0"
$pluginZip = Join-Path $build "spw-pc-overview-plugin-$pluginVersion.zip"

if (Test-Path -LiteralPath $build) {
    Remove-Item -LiteralPath $build -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $classes | Out-Null
New-Item -ItemType Directory -Force -Path $dist | Out-Null

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
Plugin-Id: com.czw.pcoverview.spw
Plugin-Name: SPW PC Overview
Plugin-Version: $pluginVersion
Plugin-Provider: czw63
Plugin-Description: Exposes current track metadata, file path and playback state as HTTP API
Plugin-Open-Source-Url: https://github.com/czw63/holocubic-pc-overview
Plugin-Has-Config: false

"@
$manifestPath = Join-Path $build "MANIFEST.MF"
Set-Content -LiteralPath $manifestPath -Value $manifest -Encoding Ascii

jar cfm $pluginJar $manifestPath -C $classes .
if ($LASTEXITCODE -ne 0) {
    throw "jar failed"
}

New-Item -ItemType Directory -Force -Path (Join-Path $dist "classes") | Out-Null
Copy-Item -LiteralPath $pluginJar -Destination (Join-Path $dist "classes") -Force
Compress-Archive -Path (Join-Path $dist "*") -DestinationPath $pluginZip -Force

Write-Host "Built $pluginZip"

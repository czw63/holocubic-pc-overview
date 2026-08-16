# SPW PC Overview Plugin

Minimal Salt Player for Windows (SPW) workshop plugin that exposes the current
track metadata, playback state and, most importantly, the current audio file
path as a tiny HTTP API.

This is the research prototype for replacing the generic Windows SMTC source
with Salt Player's own media session and for decoding the exact song file
instead of capturing every system sound.

## What the SPW Workshop API Can Do

The official `spw-workshop-api` (`PlaybackExtensionPoint`) gives a plugin:

- `title`, `artist`, `album`, `albumArtist`
- `path`: the full path of the current audio file
- playback callbacks: state, playing/paused, seek, position
- playback control methods: play, pause, next, previous, seek

It does not expose the decoded PCM audio stream or the audio renderer buffer.
For a live spectrum, the practical options are:

1. Keep WASAPI loopback, which follows whatever the default endpoint plays.
2. Use the exposed file `path`, then decode that file yourself with
   `ffmpeg`/NAudio. This can isolate the spectrum to the exact Salt Player
   track, but needs to follow the current playback position.

## HTTP API

The plugin listens on `127.0.0.1:8091` by default.

```text
GET /api/media
```

```json
{
  "ok": true,
  "title": "City of Stars",
  "artist": "Ryan Gosling / Emma Stone",
  "album": "La La Land",
  "albumArtist": "Various Artists",
  "path": "C:\\Music\\City of Stars.flac",
  "playing": true,
  "state": "Ready",
  "position": 123456
}
```

Set the port with the `SPW_PC_OVERVIEW_PORT` environment variable or the
`spw.pc.overview.port` system property.

## Automatic Bridge Lifecycle

When the plugin starts, it can launch the existing PC Overview bridge as a
hidden PowerShell process. The bridge receives `-SaltPluginUrl` so it uses
this plugin for Salt Player media metadata and file paths instead of SMTC.

On track changes the plugin notifies the bridge immediately through
`/salt-media-changed`, so the HoloCubic refreshes without waiting for a poll
interval.

Set `PC_OVERVIEW_BRIDGE_DIR` to the `service/` folder of the PC Overview
project, for example:

```text
PC_OVERVIEW_BRIDGE_DIR=D:\czw\Documents\ChatGPT\holocubic\pc_overview\service
```

If the bridge is already listening on port 8088, the plugin skips autostart.
Set `PC_OVERVIEW_AUTOSTART_BRIDGE=false` to disable this feature.

## Build

The prototype compiles with only the JDK. The `stubs/` tree mirrors the small
part of the SPW API used here, so no Maven/JitPack downloads are needed to
verify the shape of the plugin.

```powershell
.\build.ps1
```

Output:

```text
build/plugin-SPWPCOverview-0.1.0.zip
```

The zip follows the SPW workshop package layout used by existing plugins:

```text
META-INF/MANIFEST.MF
classes/META-INF/MANIFEST.MF
classes/META-INF/extensions.idx
classes/com/czw/pcoverview/spw/...
lib/
```

## Install

1. Open SPW -> Settings -> Workshop -> Mod management -> Import.
2. Import `plugin-SPWPCOverview-0.1.0.zip`.
3. Enable the mod and restart SPW once as recommended by SPW.

Then check:

```text
http://127.0.0.1:8091/api/media
```

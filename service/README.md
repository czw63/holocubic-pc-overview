# PC Overview Bridge

Self-contained Windows bridge for the HoloCubic `pc_overview` app. No external
packages are required.

## Requirements

- Windows 10/11
- Windows PowerShell 5.1 (`powershell.exe`, included with Windows)
- A music app that publishes SMTC metadata
- Default audio render endpoint for WASAPI loopback spectrum capture

## Run

Double-click `start_bridge.bat`, or run:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File pc_bridge.ps1
```

The bridge listens on `0.0.0.0:8088`. Allow the port in the Windows Firewall
for private networks, then verify:

- `http://<pc-ip>:8088/` browser test page
- `http://<pc-ip>:8088/state`
- `ws://<pc-ip>:8088/ws`

Spectrum values are sent as a 32-byte UDP datagram to the HoloCubic on port
8090 (unicast to the device when its WebSocket is connected, otherwise
broadcast). The device draws the bars locally instead of receiving a full
frame, so the bridge no longer renders spectrum pixels itself.

Use `-Port 9000` to change the bridge port, `-UdpPort 9001` to change the UDP
port, and `-NoSpectrum` to disable loopback capture. `-SelfTest` checks RGB565
cover conversion and exits.

When `Salt Player for Windows` is running, the bridge automatically captures
only that process tree with the Windows process-loopback API. Override the
target with:

```text
-SpectrumProcessName "Spotify"
-SpectrumProcessId 1234
```

The process-loopback capture uses `ApplicationLoopback.dll` from
`ApplicationLoopback.NET` (MIT). See `THIRD_PARTY_NOTICES.md`.

When the SPW plugin is running, start the bridge with its media API to use
Salt Player metadata and the current file path instead of SMTC:

```text
-SaltPluginUrl http://127.0.0.1:8091
```

The plugin uses this mode when it autostarts the bridge.

On track changes the SPW plugin calls `/salt-media-changed` on the bridge.
The bridge wakes its main loop with an event instead of waiting for the next
100 ms fallback poll. Track title/artist/album are pushed to the device first;
the cover is resolved right after, so a slow cover must never hold up the text
update.

Album covers are fetched from the SPW plugin's `/api/cover` endpoint, which
reads the embedded artwork in-process with JAudioTagger. `ffmpeg` is only a
fallback for files the plugin cannot parse; the current SMTC thumbnail is used
when the file itself has no embedded artwork.

`bridge_server.cs` implements the HTTP/WebSocket server. `audio_capture.cs`
implements the WASAPI loopback capture and log-spaced spectrum analysis. The
PowerShell script compiles both files with `Add-Type` at startup.

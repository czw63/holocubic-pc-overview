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

`bridge_server.cs` implements the HTTP/WebSocket server. `audio_capture.cs`
implements the WASAPI loopback capture and log-spaced spectrum analysis. The
PowerShell script compiles both files with `Add-Type` at startup.

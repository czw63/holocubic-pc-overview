# HoloCubic PC Overview

A 320x240 HoloCubic app plus a self-contained Windows bridge that turns the
cube into a PC status display:

- SMTC music title, artist, album, player name and 96x96 album cover
- CPU, GPU and RAM usage from the Windows machine
- Local weather from the built-in CubicServer weather API
- Local time and date
- Live WASAPI spectrum with smooth local bar rendering; when Salt Player for
  Windows is running, only its audio process is captured

中文文档：[README_ZH.md](README_ZH.md)

![Preview](preview_320x240.png)

## Repository Layout

```text
holocubic-pc-overview/
  package/   HoloCubic app, deploy to /sd/apps/pc_overview/
  service/   Windows bridge: SMTC, system metrics, WASAPI spectrum
  spw-plugin/ Salt Player for Windows plugin prototype
  docs/      Protocol and performance notes
  preview_320x240.png
```

## Device Install

1. Copy the contents of `package/` to `/sd/apps/pc_overview/`.
2. Make sure the `weather` app is installed. Its fonts are reused so Chinese
   and Japanese music metadata can render correctly.
3. Rescan apps in the launcher and open `PC Overview`.
4. Open the app WebUI at `http://<holocubic-ip>/pc-overview/` and set the PC
   IP and bridge port.

## Windows Bridge

The bridge requires Windows 10/11 and Windows PowerShell 5.1
(`powershell.exe`):

```text
service\start_bridge.bat
```

It listens on `0.0.0.0:8088` by default and serves:

- `http://<pc-ip>:8088/` browser test page
- `http://<pc-ip>:8088/state` JSON state
- `http://<pc-ip>:8088/cover` RGB565 cover bytes
- `ws://<pc-ip>:8088/ws` state and spectrum WebSocket

Allow port 8088 through the Windows Firewall for private networks. The music
app must publish SMTC metadata; most desktop players do.

For spectrum capture, the bridge automatically targets the `Salt Player for
Windows` process tree when it is running. Otherwise it falls back to the
default WASAPI render endpoint.

## Performance

Spectrum data is sent as a 32-byte UDP datagram on port 8090. The HoloCubic
draws the bars locally instead of receiving a pre-rendered RGB565 frame. This
matches the approach used by the built-in HoloCubic Spectrum app and keeps the
network and Lua runtime load small even at high update rates.

See [docs/PROTOCOL.md](docs/PROTOCOL.md),
[docs/PERFORMANCE.md](docs/PERFORMANCE.md) and
[docs/SPW_INTEGRATION.md](docs/SPW_INTEGRATION.md) for details.

## License

MIT

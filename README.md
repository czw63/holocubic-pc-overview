# HoloCubic PC Overview

A 320x240 HoloCubic app plus a self-contained PC bridge (Windows or Linux) that
turns the cube into a status display:

- Music title, artist, album, player name and 96x96 album cover (SMTC on
  Windows, MPRIS on Linux)
- CPU, GPU and RAM usage from the PC
- Local weather from the built-in CubicServer weather API
- Local time and date
- Live spectrum with smooth local bar rendering (WASAPI loopback on Windows,
  PipeWire/PulseAudio sink monitor on Linux); when Salt Player for Windows is
  running, only its audio process is captured

中文文档：[README_ZH.md](README_ZH.md)

![Preview](preview_320x240.png)

## Repository Layout

```text
holocubic-pc-overview/
  package/        HoloCubic app, deploy to /sd/apps/pc_overview/
  service/        Windows bridge: SMTC, system metrics, WASAPI spectrum
  service-linux/  Linux bridge: MPRIS, /proc metrics, PipeWire spectrum
  spw-plugin/     Salt Player for Windows plugin prototype
  docs/           Protocol and performance notes
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

`-ServiceMode` runs the bridge as a logon background service: system metrics
stay on all the time, while music metadata and spectrum activate automatically
when Salt Player for Windows starts. See `service/README.md`.

Allow port 8088 through the Windows Firewall for private networks. The music
app must publish SMTC metadata; most desktop players do.

For spectrum capture, the bridge automatically targets the `Salt Player for
Windows` process tree when it is running. Otherwise it falls back to the
default WASAPI render endpoint.

## Linux Bridge

`service-linux/pc_bridge.py` speaks the same protocol, so the same device app
works without changes. No vendor plugins are needed: music comes from MPRIS, so
Spotify, Firefox, mpv, VLC and friends all report metadata out of the box.

```sh
python3 service-linux/pc_bridge.py          # HTTP on 0.0.0.0:8088
python3 service-linux/pc_bridge.py --list-players
```

Requires `python-dbus`, `parec` (pulseaudio-utils), Pillow, and optionally
NumPy plus ffmpeg. A systemd user unit and a mock MPRIS player for testing live
in `service-linux/`, see [service-linux/README.md](service-linux/README.md).

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

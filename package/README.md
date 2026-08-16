# PC Overview

320x240 HoloCubic app showing:

- SMTC music title, artist, album, app and 96x96 RGB565 album cover
- CPU, GPU and RAM usage from the Windows bridge
- Local weather through the existing CubicServer weather API
- Local time and date
- Live WASAPI loopback spectrum from the PC (32-byte bars over UDP, with a
  WebSocket fallback; the device draws the bars locally)

## Install

Copy this `package/` directory to `/sd/apps/pc_overview/`, rescan apps in the
launcher, then open the app. The launcher WebUI route is `/pc_overview`.

Chinese and Japanese UI fonts (12px/16px) are borrowed from the `weather` app
(`/sd/apps/weather/font/weather_ui_zh_cn_*.bin` and
`weather_ui_ja_*.bin`). Install the weather app too if Chinese/Japanese music
metadata should render.

## Windows bridge

The `../service/` folder contains a self-contained Windows PowerShell 5.1 bridge:

```text
pc_overview/service/
  start_bridge.bat
  pc_bridge.ps1
  bridge_server.cs
  audio_capture.cs
```

Run `start_bridge.bat` on the PC with `powershell.exe` (Windows PowerShell
5.1). It listens on port 8088 by default:

- `http://<pc-ip>:8088/` browser test page
- `http://<pc-ip>:8088/state` JSON state
- `http://<pc-ip>:8088/cover` RGB565 cover bytes
- `ws://<pc-ip>:8088/ws` state and spectrum WebSocket

Allow port 8088 through the Windows Firewall for private networks. The music
app must publish SMTC (most desktop players do). Spectrum uses WASAPI loopback
capture, so it follows whatever the default render endpoint plays.
The bridge also sends the 32 spectrum bar values to the device on UDP 8090,
which keeps the display refresh cheap even at high update rates.

Set the PC IP and port in the app WebUI, then reopen the app.

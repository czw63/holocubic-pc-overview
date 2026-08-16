# Protocol

## HTTP

The bridge exposes these endpoints:

| Endpoint | Description |
| --- | --- |
| `/state` | JSON state: media, system usage, cover version |
| `/spectrum` | Latest spectrum as JSON: `{"type":"spectrum","bins":[...]}` |
| `/cover` | Raw RGB565 cover bytes |
| `/cover64` | Cover encoded as base64 JSON |
| `/health` | Bridge status, client count and spectrum counters |

## WebSocket

`ws://<pc-ip>:8088/ws` sends:

- Text frames with `type=state` JSON when state changes or once per second
- Binary frames with a 32-byte spectrum payload

Each spectrum byte is a normalized bar value `0..255`, where `255` is full
height.

## UDP Spectrum

The bridge sends the same 32-byte spectrum payload over UDP port `8090`:

- Unicast to the WebSocket client's source IP when a HoloCubic is connected
- Broadcast to `255.255.255.255:8090` as a fallback

The device listens with `net.createUDPSocket()` and draws the bars locally.
WebSocket binary remains as a fallback so a single missing UDP packet does not
freeze the display.

## Device State API

The app WebUI exposes:

| Endpoint | Description |
| --- | --- |
| `/pc-overview/api/state` | Current app config and runtime counters |
| `/pc-overview/api/save` | Save bridge and display settings |

Runtime counters include:

- `spectrum_frames`: spectrum datagrams handled
- `spectrum_udp_frames`: spectrum datagrams received over UDP
- `spectrum_frame_len`: current payload length, normally 32
- `cover_bytes` / `cover_loaded`: album cover state
- `app_status`: `LIVE`, `STALE` or `OFFLINE`

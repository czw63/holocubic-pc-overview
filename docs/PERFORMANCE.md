# Performance Notes

## Why 32 Bytes Instead of a Full Frame

The first working version sent a 300x46 RGB565 spectrum frame from the PC over
WebSocket. That is 27,600 bytes per frame. At 50 fps it becomes about 1.4 MB/s
of WebSocket bursts, which is enough to make both the bridge and the Lua
runtime stutter.

The current version sends only 32 bar values as one UDP datagram:

```text
27,600 bytes/frame  ->  32 bytes/frame
```

The HoloCubic draws the bars itself on a small 300x46 canvas. This is the same
strategy as the built-in HoloCubic Spectrum app, which redraws a full
320x240 canvas on a 23 ms timer.

## Device Timing

- Full dashboard redraw: `config.full_refresh_ms`, default 500 ms
- Spectrum canvas timer: 20 ms, only redraws when new data arrived
- State WebSocket reconnect timeout: `config.timeout_ms`, default 6000 ms
- Stale connection timeout: `config.stale_ms`, default 5000 ms

## PC Bridge Timing

- Media SMTC poll: 250 ms
- System metrics poll: 1000 ms
- Spectrum FFT: log-spaced Goertzel bins over 1024 samples
- Spectrum send throttle: at most one datagram every 20 ms
- Process target: Salt Player for Windows process tree when running,
  otherwise the default render endpoint

## Tuning

- `refresh_ms` controls the lightweight dashboard tick, minimum 30 ms
- `full_refresh_ms` controls full canvas redraw, keep it at 500 ms or above
- `spectrum = false` disables spectrum entirely
- `NoSpectrum` on the bridge disables WASAPI capture

## Capturing Only a Single Player

The default bridge uses WASAPI loopback, so it follows everything the default
render endpoint plays. Capturing only one app's audio requires either a
per-process audio session integration or routing that player through a virtual
audio cable. The project keeps loopback mode as the simple default.

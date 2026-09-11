# Linux Bridge

The same PC Overview bridge, ported from Windows PowerShell + C# to Python.  It
speaks the identical protocol, so the device app in `package/` is unchanged and
both bridges can be used interchangeably (one PC at a time).

| Windows piece | Linux replacement |
| --- | --- |
| WinRT SMTC (`Get-MediaSnapshot`) | MPRIS over the session D-Bus |
| WASAPI loopback / process loopback | PipeWire or PulseAudio sink monitor (`parec`) |
| `PerformanceCounter`, WMI GPU | `/proc/stat`, `/proc/meminfo`, amdgpu sysfs (`nvidia-smi` fallback) |
| .NET `HttpListener` + C# server | asyncio HTTP + WebSocket server |
| `System.Drawing` cover scaling | Pillow |
| Salt Player for Windows plugin | none needed, players publish MPRIS themselves |

## Requirements

* Python 3.9 or newer
* `python-dbus` (session bus access)
* `parec` from `pulseaudio-utils` - talks to PipeWire through `pipewire-pulse`
  or to PulseAudio directly
* Pillow and NumPy (`python-pillow`, `python-numpy`) - Pillow is required for
  cover art, NumPy is optional and only makes the spectrum cheap
* `ffmpeg` (optional) for the embedded-art fallback when a player publishes no
  `mpris:artUrl`

On Arch / CachyOS:

```sh
sudo pacman -S python-dbus python-pillow python-numpy pulseaudio-utils
```

## Run It

```sh
python3 service-linux/pc_bridge.py
```

Then point the device app at `http://<pc-ip>:8088/` and open
`http://localhost:8088/` in a browser to check the state.

Useful flags:

| Flag | Meaning |
| --- | --- |
| `--port 8088` | HTTP/WebSocket port |
| `--udp-port 8090` | spectrum UDP port (`0` disables UDP) |
| `--spectrum-source auto` | `auto` = default sink monitor, or pass an explicit `<sink>.monitor` |
| `--no-spectrum` | skip audio capture entirely (dashboard still works) |
| `--player spotify` | prefer a player whose bus name or identity contains this text |
| `--list-players` | print the MPRIS players visible right now and exit |
| `--media-poll-ms 100` | MPRIS poll interval |

## Run It in the Background

```sh
mkdir -p ~/.config/systemd/user
cp service-linux/holocubic-bridge.service ~/.config/systemd/user/
$EDITOR ~/.config/systemd/user/holocubic-bridge.service   # fix ExecStart
systemctl --user daemon-reload
systemctl --user enable --now holocubic-bridge.service
loginctl enable-linger "$USER"
```

With lingering enabled the bridge comes back after a reboot even before anyone
logs in, and `journalctl --user -u holocubic-bridge -f` shows the logs.

## What Is Captured

The spectrum follows the **default output device**, which is the Linux
equivalent of the Windows bridge's default WASAPI loopback: everything the PC
plays is visible on the cube.

Single-application capture has no direct equivalent because PipeWire mixes into
one sink.  Two options that work:

1. Route the player into its own sink and capture that:

   ```sh
   pactl load-module module-null-sink sink_name=holo
   pactl move-sink-input "$(pactl list short sink-inputs | awk '{print $1; exit}')" holo
   python3 service-linux/pc_bridge.py --spectrum-source holo.monitor
   ```

2. Give the player its own output device in its settings, then capture that
   device's monitor by name with `--spectrum-source`.

## Notes on Fidelity

The port keeps the Windows behaviour where it is observable:

* 96x96 RGB565 covers, little endian, matching the `System.Drawing` bitmap
  stretch (album art is resized to fill, not letterboxed).
* Cover version plus `cover_ready` handshake: on a track change the version is
  bumped and `cover_ready` drops to `false`, so the device keeps the previous
  cover until the new one is decoded.
* 32 log-spaced bands from 60 Hz to 16 kHz, 1024 sample windows with 50 %
  overlap, `pow(raw, 0.65)` shaping and 0.3/0.7 smoothing - the same math as
  `service/audio_capture.cs`.
* UDP spectrum datagrams (32 bytes, one every 20 ms) go to every connected
  WebSocket client, with a `255.255.255.255` broadcast fallback when no client
  is connected yet.

Two deliberate differences:

* The Goertzel loop is replaced by an equivalent FFT magnitude per band when
  NumPy is available, because 32 x 1024 sequential Goertzel steps per frame is
  expensive in Python.  The amplitudes match (`|X|/N` for both), and the pure
  Python Goertzel path is still there as a fallback.
* GPU usage comes from `gpu_busy_percent` (AMD) or `nvidia-smi` (NVIDIA).  When
  neither is available the field keeps its previous value.

## Troubleshooting

Start here - it lists every MPRIS player the bridge can see right now:

```sh
python3 service-linux/pc_bridge.py --list-players
```

**No players listed.**  The player is running but does not publish MPRIS:

| Player | MPRIS support |
| --- | --- |
| Spotify, VLC, Rhythmbox, Elisa, Strawberry, Audacious, Firefox, Chromium | built in |
| mpv | needs the separate `mpv-mpris` package (`pacman -S mpv-mpris`) |
| `cmus`, `moc` and most CLI players | no MPRIS |

**Bars stay flat.**  Check `/health` - `"audio":true` means capture is running.
The bridge follows the *default* sink, so a player routed to another output
device (HDMI, a USB DAC) is not captured until you pass that device's monitor
with `--spectrum-source`.  `pactl list short sinks` lists the available names.

**Cover never shows up.**  `/state` carries a `cover_error` reason.  Players
that publish no `mpris:artUrl` need the optional `ffmpeg` fallback, and the file
behind `xesam:url` has to exist locally.

## Testing Without a Player

```sh
# fake MPRIS player with a generated cover
python3 service-linux/tools/mock_mpris_player.py /tmp/cover.png "夜に駆ける" YOASOBI "THE BOOK"

# what the bridge sees
python3 service-linux/pc_bridge.py --list-players
curl -s localhost:8088/state | python3 -m json.tool
```

A running tone is enough to prove the spectrum path:

```sh
ffmpeg -f lavfi -i "sine=frequency=440:duration=5" -ar 48000 -ac 2 -f pulse default
```

440 Hz should land in band 11 of 32.

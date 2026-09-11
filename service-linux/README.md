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
| `--spectrum-always` | keep capturing and broadcasting with no client connected (Windows behaviour) |
| `--player spotify` | prefer a player whose bus name or identity contains this text |
| `--gpu card1` | report this GPU instead of the busiest one |
| `--list-players` | print the MPRIS players visible right now and exit |
| `--print-metrics 5` | print CPU/GPU/RAM once per second for 5 seconds and exit |
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

### Keeping It Alive

The shipped unit is built so the bridge does not quietly disappear:

| Setting | Why |
| --- | --- |
| `Type=notify` + `WatchdogSec=90` | The bridge pings systemd every 30 s; a wedged event loop gets restarted instead of hanging forever |
| `Restart=always`, `RestartSec=2` | Any crash comes straight back |
| `StartLimitIntervalSec=0` | systemd never gives up, however often it crashes |
| no `PartOf=graphical-session.target` | Switching between Plasma and Steam Game Mode tears that target down; the bridge now keeps serving the cube across the switch |

That last one is worth remembering: with `PartOf=`, a Plasma to Game Mode switch
stops the unit as part of the session teardown, and because a *stop* is not a
crash, `Restart=always` does not bring it back - the cube just goes dark until
you start it by hand.  `systemctl --user status holocubic-bridge` is the fastest
way to check, and `systemctl --user show -p PartOf` should print nothing.

### Firewall

The device connects to this PC for everything except the spectrum, so port
**8088/tcp must be reachable from your LAN**:

```sh
sudo ufw allow 8088/tcp comment 'HoloCubic PC Overview bridge'
```

8090/udp needs no rule on this PC: the spectrum travels *outbound* (unicast to
the device, or a 255.255.255.255 broadcast), and firewalls filter inbound
traffic.  That asymmetry produces a very specific symptom worth remembering:

> **The spectrum works but the CPU/GPU/RAM readouts stay blank.**

The bars keep moving because the broadcast leaves this PC regardless of the
firewall, while every `/state` fetch and the WebSocket connection are inbound
and get dropped.  `sudo ufw status` shows whether 8088 is open; the bridge also
prints a warning at startup when it detects a default-deny ufw without a rule
for its port.

Two more things that look similar and are not firewall problems:

* A browser test on the PC itself always works, because traffic to your own
  address goes over `lo`, which firewalls leave open.
* If the device connects but only ever fetches `/state`, check the app version:
  the app only polls state over HTTP when the WebSocket module is missing.

## What Is Captured

### System metrics

The dashboard shows the same three numbers as the Windows bridge, read from a
different place:

| Field | Windows source | Linux source |
| --- | --- | --- |
| `cpu` | `\Processor(_Total)\% Processor Time` | `/proc/stat` delta, all cores averaged into one 0-100 number |
| `mem` / `mem_used` / `mem_total` | `Win32_OperatingSystem` total minus free | `/proc/meminfo`: `MemTotal - MemAvailable`, in GiB |
| `gpu` | sum of `\GPU Engine(*)\Utilization Percentage`, capped at 100 | `gpu_busy_percent` (amdgpu sysfs), `nvidia-smi` fallback |

Notes:

* **Memory uses "available", not "free".**  `MemTotal - MemAvailable` is the
  same definition Task Manager and `free`'s `used` column use.  The naive
  `MemTotal - MemFree` would report around 90 % on a healthy Linux desktop
  because the page cache counts as used, which is not what the gauge should
  show.
* **Multi-GPU machines report the busiest card.**  Machines with an iGPU and a
  dGPU expose two `gpu_busy_percent` files; the bridge takes the larger one so
  the gauge follows whichever GPU is actually working.  Pin one explicitly with
  `--gpu card1` (`--print-metrics` shows which file each number came from).
* **No GPU counter?**  Intel GPUs and some older AMD kernels do not expose
  `gpu_busy_percent` and have no `nvidia-smi`; the gauge then keeps its previous
  value instead of dropping to zero.

To check the numbers on any machine, including whether the GPU source is the
one you expect:

```sh
python3 service-linux/pc_bridge.py --print-metrics 5
# cpu=  4%  gpu= 98%  mem= 36%   8.2/22.6 GB  [/sys/class/drm/card1/device/gpu_busy_percent]
```

### Spectrum

The spectrum follows the **default output device**, which is the Linux
equivalent of the Windows bridge's default WASAPI loopback: everything the PC
plays is visible on the cube.

It only runs while something is watching.  The capture stream stays open (that
costs almost nothing) but the FFT and the datagrams are skipped until a device
connects, and pause again 10 seconds after the last `/state` request or
WebSocket disconnects.  Idle cost drops from roughly 4 % CPU plus a permanent
50 packets/s LAN broadcast to about 0.4 % and no traffic.  `--spectrum-always`
restores the always-on behaviour.

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

One deliberate difference: the Goertzel loop is replaced by an equivalent FFT
magnitude per band when NumPy is available, because 32 x 1024 sequential
Goertzel steps per frame is expensive in Python.  The amplitudes match
(`|X|/N` for both), and the pure Python Goertzel path is still there as a
fallback.

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

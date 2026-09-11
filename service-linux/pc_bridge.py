#!/usr/bin/env python3
"""
HoloCubic PC Overview - Linux bridge.

Speaks the same HTTP / WebSocket / UDP protocol as the Windows bridge
(``service/pc_bridge.ps1`` + ``service/bridge_server.cs``), so the device app in
``package/`` runs unchanged:

===============  =======================================================
``GET /state``   dashboard state: media metadata + system usage
``GET /spectrum`` latest spectrum as JSON
``GET /cover``   raw RGB565 cover bytes (96x96, little endian)
``GET /cover64`` cover as base64 JSON
``GET /health``  bridge counters and audio capture state
``GET /``        tiny status page for eyeballing the bridge
``GET /ws``      WebSocket: text ``state`` frames, binary spectrum frames
UDP port        32 byte spectrum payload, unicast to connected clients
===============  =======================================================

The Windows-only pieces are replaced like this:

==============================  ==========================================
Windows                         Linux
==============================  ==========================================
WinRT SMTC (``Get-MediaSnapshot``)  MPRIS over the session D-Bus
WASAPI loopback / process loopback  PipeWire or PulseAudio sink monitor
PerformanceCounter, WMI GPU     /proc/stat, /proc/meminfo, amdgpu sysfs
.NET HttpListener + C# server   asyncio HTTP + WebSocket server
System.Drawing cover scaling    Pillow
==============================  ==========================================

Run it directly::

    python3 service-linux/pc_bridge.py --spectrum-source auto

or install ``service-linux/holocubic-bridge.service`` as a systemd user unit.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import contextlib
import io
import json
import math
import os
import re
import shutil
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
from typing import Any, Dict, List, Optional, Sequence

COVER_SIZE = 96
COVER_BYTES = COVER_SIZE * COVER_SIZE * 2

SPECTRUM_BINS = 32
FFT_SIZE = 1024
FFT_OVERLAP = FFT_SIZE // 2
SPECTRUM_MIN_HZ = 60.0
SPECTRUM_MAX_HZ = 16000.0
CAPTURE_RATE = 48000
CAPTURE_CHANNELS = 2

MPRIS_PREFIX = "org.mpris.MediaPlayer2."
MPRIS_PLAYER_IFACE = "org.mpris.MediaPlayer2.Player"
MPRIS_ROOT_IFACE = "org.mpris.MediaPlayer2"
PROPERTIES_IFACE = "org.freedesktop.DBus.Properties"

SMOOTH_KEEP = 0.3
SMOOTH_NEW = 0.7
CURVE = 0.65

ARGV0 = os.path.basename(sys.argv[0]) if sys.argv and sys.argv[0] else "pc_bridge"


# --------------------------------------------------------------------------
# small helpers
# --------------------------------------------------------------------------


def log(message: str, *args: Any) -> None:
    text = message % args if args else message
    print("%s %s" % (time.strftime("[%H:%M:%S]"), text), flush=True)


def dumps(payload: Any) -> str:
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":"))


def clamp(value: float, low: float, high: float) -> float:
    if value != value:  # NaN
        return low
    return low if value < low else high if value > high else value


def text(value: Any) -> str:
    if value is None:
        return ""
    return str(value).strip()


def firewall_hint(port: int) -> str:
    """Warn when a default-deny ufw setup is going to drop the device.

    The device connects *to* this PC, so an inbound firewall rule is required.
    A local browser test on the PC itself always works because that traffic
    goes over ``lo``, which firewalls leave open - which makes this a
    confusing failure to diagnose from the device side.
    """
    try:
        with open("/etc/ufw/ufw.conf", "r") as handle:
            if not re.search(r"^ENABLED=yes", handle.read(), re.M):
                return ""
    except OSError:
        return ""

    policy = ""
    try:
        with open("/etc/default/ufw", "r") as handle:
            for line in handle:
                if line.startswith("DEFAULT_INPUT_POLICY="):
                    policy = line.split("=", 1)[1].strip().strip('"')
    except OSError:
        return ""
    if policy != "DROP":
        return ""

    try:
        with open("/etc/ufw/user.rules", "r") as handle:
            rules = handle.read()
    except OSError:
        rules = ""
    if re.search(r"--dports?\s+%d\b" % port, rules):
        return ""
    return (
        "ufw is enabled with DEFAULT_INPUT_POLICY=DROP and no rule opens port %d, "
        "so the device cannot reach this bridge (the spectrum still arrives "
        "because it is broadcast outbound). Fix with:  sudo ufw allow %d/tcp"
        % (port, port)
    )


# --------------------------------------------------------------------------
# system metrics: CPU / GPU / RAM
# --------------------------------------------------------------------------


class MetricsSampler:
    """Lightweight /proc reader, same three numbers the Windows sampler reports."""

    def __init__(self, gpu_filter: str = "auto") -> None:
        self.cpu = 0.0
        self.gpu = 0.0
        self.mem = 0.0
        self.mem_used: Optional[float] = None
        self.mem_total: Optional[float] = None
        self.gpu_filter = (gpu_filter or "auto").strip()
        self.gpu_source = ""
        self._prev_cpu: Optional[tuple] = None
        self._nvidia: Optional[bool] = None
        self._gpu_warned = False

    def sample(self) -> None:
        self._sample_cpu()
        self._sample_memory()
        self._sample_gpu()

    # -- cpu ---------------------------------------------------------------
    def _sample_cpu(self) -> None:
        try:
            with open("/proc/stat", "r") as handle:
                first = handle.readline()
            fields = [int(part) for part in first.split()[1:]]
            idle = fields[3] + (fields[4] if len(fields) > 4 else 0)
            total = sum(fields)
        except (OSError, ValueError, IndexError):
            return
        if self._prev_cpu is not None:
            idle_delta = idle - self._prev_cpu[0]
            total_delta = total - self._prev_cpu[1]
            if total_delta > 0:
                busy = 100.0 * (1.0 - float(idle_delta) / float(total_delta))
                self.cpu = clamp(busy, 0.0, 100.0)
        self._prev_cpu = (idle, total)

    # -- memory ------------------------------------------------------------
    def _sample_memory(self) -> None:
        info: Dict[str, int] = {}
        try:
            with open("/proc/meminfo", "r") as handle:
                for line in handle:
                    key, _, rest = line.partition(":")
                    if key in ("MemTotal", "MemAvailable"):
                        info[key] = int(rest.split()[0]) * 1024
        except (OSError, ValueError, IndexError):
            return
        total = info.get("MemTotal")
        available = info.get("MemAvailable")
        if not total or available is None:
            return
        used = max(0, total - available)
        gb = 1024.0 ** 3
        self.mem_used = round(used / gb, 1)
        self.mem_total = round(total / gb, 1)
        self.mem = clamp(100.0 * used / total, 0.0, 100.0)

    # -- gpu ---------------------------------------------------------------
    def _sample_gpu(self) -> None:
        import glob

        paths = sorted(glob.glob("/sys/class/drm/card*/device/gpu_busy_percent"))
        if paths:
            chosen = paths
            if self.gpu_filter not in ("auto", "max", ""):
                wanted = [
                    path for path in paths
                    if path.startswith("/sys/class/drm/%s/" % self.gpu_filter)
                ]
                if wanted:
                    chosen = wanted
                elif not self._gpu_warned:
                    log(
                        "gpu %s has no gpu_busy_percent, using %s",
                        self.gpu_filter,
                        ", ".join(paths),
                    )
                    self._gpu_warned = True
            readings = []
            for path in chosen:
                try:
                    with open(path, "r") as handle:
                        readings.append((int(handle.read().strip()), path))
                except (OSError, ValueError):
                    continue
            if readings:
                value, path = max(readings)
                self.gpu_source = path
                self.gpu = clamp(float(value), 0.0, 100.0)
                return
        self._sample_gpu_nvidia()

    def _sample_gpu_nvidia(self) -> None:
        if self._nvidia is False:
            return
        if self._nvidia is None:
            self._nvidia = shutil.which("nvidia-smi") is not None
            if not self._nvidia:
                return
        try:
            out = subprocess.run(
                [
                    "nvidia-smi",
                    "--query-gpu=utilization.gpu",
                    "--format=csv,noheader,nounits",
                ],
                capture_output=True,
                text=True,
                timeout=2.0,
            )
            values = [
                float(line) for line in out.stdout.split() if line.strip()
            ]
            if values:
                self.gpu = clamp(max(values), 0.0, 100.0)
                self.gpu_source = "nvidia-smi"
        except (OSError, ValueError, subprocess.SubprocessError):
            self._nvidia = False


# --------------------------------------------------------------------------
# media: MPRIS over the session bus
# --------------------------------------------------------------------------


class MprisMedia:
    """Polls every MPRIS player and returns the one worth showing.

    The Windows bridge reads SMTC, which only exists on Windows.  MPRIS is the
    Linux equivalent and is implemented by essentially every player (Spotify,
    Firefox, mpv, VLC, Strawberry, Amberol, ...), so no per-player plugin is
    needed - the Salt Player extension in ``spw-plugin/`` has no counterpart
    here by design.
    """

    def __init__(self, preferred: Optional[str] = None) -> None:
        self.preferred = preferred.lower() if preferred else None
        self._bus = None
        self._dbus = None
        self._identity: Dict[str, str] = {}
        self._changed_at: Dict[str, float] = {}
        self._last_key: Dict[str, str] = {}
        self.error = ""

    # -- connection --------------------------------------------------------
    def connect(self) -> bool:
        if self._bus is not None:
            return True
        try:
            import dbus  # type: ignore
        except ImportError:
            self.error = "python-dbus not installed"
            return False
        try:
            self._dbus = dbus
            self._bus = dbus.SessionBus()
        except Exception as exc:  # noqa: BLE001 - dbus raises many types
            self.error = "session bus unavailable: %s" % exc
            self._bus = None
            return False
        self.error = ""
        return True

    # -- polling -----------------------------------------------------------
    def poll(self) -> Optional[Dict[str, Any]]:
        """Return the best current snapshot, or ``None`` when nothing is open."""
        if not self.connect():
            return None
        try:
            names = [
                str(name)
                for name in self._bus.call_blocking(
                    "org.freedesktop.DBus",
                    "/org/freedesktop/DBus",
                    "org.freedesktop.DBus",
                    "ListNames",
                    signature="",
                    args=[],
                    timeout=2.0,
                )
            ]
        except Exception as exc:  # noqa: BLE001
            self.error = "ListNames failed: %s" % exc
            self._bus = None
            return None

        snapshots = []
        for name in names:
            if not name.startswith(MPRIS_PREFIX) or name[len(MPRIS_PREFIX):].isdigit():
                continue
            snapshot = self._read_player(name)
            if snapshot:
                snapshots.append(snapshot)
        if not snapshots:
            return None

        if self.preferred:
            wanted = [
                snap
                for snap in snapshots
                if self.preferred in snap["bus"].lower()
                or self.preferred in snap["app"].lower()
            ]
            if wanted:
                snapshots = wanted

        playing = [snap for snap in snapshots if snap["playing"]]
        pool = playing or snapshots
        pool.sort(key=lambda snap: self._changed_at.get(snap["bus"], 0.0), reverse=True)
        return pool[0]

    def _read_player(self, name: str) -> Optional[Dict[str, Any]]:
        try:
            player = self._get_all(name, MPRIS_PLAYER_IFACE)
            status = text(player.get("PlaybackStatus")) or "Stopped"
            metadata = player.get("Metadata") or {}
        except Exception as exc:  # noqa: BLE001 - a player can vanish mid-poll
            self.error = "%s: %s" % (name[len(MPRIS_PREFIX):], exc)
            return None
        self.error = ""

        title = text(metadata.get("xesam:title"))
        artist = self._join_artist(metadata.get("xesam:artist"))
        album = text(metadata.get("xesam:album"))
        art_url = text(metadata.get("mpris:artUrl"))
        url = text(metadata.get("xesam:url"))
        app = self._player_identity(name)

        bus_key = "|".join((app, title, artist, album, art_url))
        previous = self._last_key.get(name)
        if previous != bus_key:
            self._last_key[name] = bus_key
            self._changed_at[name] = time.monotonic()

        return {
            "bus": name,
            "app": app,
            "title": title,
            "artist": artist,
            "album": album,
            "art_url": art_url,
            "url": url,
            "status": status,
            "playing": status.lower() == "playing",
            "key": bus_key,
        }

    def _player_identity(self, name: str) -> str:
        if name in self._identity:
            return self._identity[name]
        identity = ""
        try:
            identity = text(self._get(name, MPRIS_ROOT_IFACE, "Identity"))
        except Exception:  # noqa: BLE001
            identity = ""
        if not identity:
            identity = name[len(MPRIS_PREFIX):].split(".")[0]
        self._identity[name] = identity
        return identity

    # -- raw calls ---------------------------------------------------------
    # ``call_blocking`` with explicit signatures skips client side introspection,
    # which some players implement slowly or not at all.
    def _get_all(self, name: str, interface: str) -> Dict[str, Any]:
        return self._call(name, PROPERTIES_IFACE, "GetAll", "s", [interface])

    def _get(self, name: str, interface: str, prop: str) -> Any:
        return self._call(name, PROPERTIES_IFACE, "Get", "ss", [interface, prop])

    def _call(
        self,
        name: str,
        interface: str,
        method: str,
        in_signature: str,
        args: list,
    ) -> Any:
        return self._bus.call_blocking(
            name,
            "/org/mpris/MediaPlayer2",
            interface,
            method,
            signature=in_signature,
            args=args,
            timeout=2.0,
        )

    @staticmethod
    def _join_artist(value: Any) -> str:
        if not value:
            return ""
        if isinstance(value, (list, tuple)):
            return ", ".join(text(item) for item in value if text(item))
        return text(value)


# --------------------------------------------------------------------------
# cover art: MPRIS artUrl -> 96x96 RGB565 little endian
# --------------------------------------------------------------------------


class CoverBuilder:
    def __init__(self, debug: bool = False) -> None:
        self.debug = debug
        self.last_error = ""
        self._remote_cache: Dict[str, tuple] = {}

    def resolve(self, art_url: str, track_url: str) -> Optional[bytes]:
        """Fetch, scale and pack the cover.  Returns ``None`` when unavailable."""
        raw = None
        source = ""
        if art_url:
            try:
                raw = self._load_art_url(art_url)
                source = art_url
            except Exception as exc:  # noqa: BLE001
                self.last_error = "artUrl failed: %s" % exc
        if raw is None and track_url and track_url.startswith("file://"):
            try:
                raw = self._embedded_art(track_url)
                source = track_url + " (embedded)"
            except Exception as exc:  # noqa: BLE001
                self.last_error = "embedded art failed: %s" % exc
        if raw is None:
            if not self.last_error:
                self.last_error = "no cover source"
            return None
        try:
            packed = self.to_rgb565(raw)
        except Exception as exc:  # noqa: BLE001
            self.last_error = "decode failed: %s" % exc
            return None
        if self.debug:
            log("cover resolved from %s (%d bytes in, %d out)", source, len(raw), len(packed))
        self.last_error = ""
        return packed

    # -- sources -----------------------------------------------------------
    def _load_art_url(self, art_url: str) -> Optional[bytes]:
        if art_url.startswith("file://"):
            from urllib.parse import unquote, urlparse

            path = unquote(urlparse(art_url).path)
            if not os.path.exists(path):
                raise FileNotFoundError(path)
            with open(path, "rb") as handle:
                return handle.read()
        if art_url.startswith("data:"):
            _, _, payload = art_url.partition(",")
            return base64.b64decode(payload)
        if art_url.startswith(("http://", "https://")):
            cache = self._remote_cache.get(art_url)
            if cache and time.monotonic() - cache[0] < 600:
                return cache[1]
            from urllib.request import Request, urlopen

            request = Request(art_url, headers={"User-Agent": "holocubic-pc-overview"})
            with urlopen(request, timeout=4.0) as response:  # noqa: S310 - player supplied URL
                data = response.read(8 * 1024 * 1024)
            self._remote_cache[art_url] = (time.monotonic(), data)
            return data
        return None

    def _embedded_art(self, track_url: str) -> Optional[bytes]:
        """ffmpeg fallback for players that expose a file but no artUrl."""
        from urllib.parse import unquote, urlparse

        if not shutil.which("ffmpeg"):
            return None
        path = unquote(urlparse(track_url).path)
        if not os.path.exists(path):
            return None
        out = subprocess.run(
            ["ffmpeg", "-v", "error", "-i", path, "-an", "-c:v", "mjpeg", "-f", "image2", "-"],
            capture_output=True,
            timeout=4.0,
        )
        return out.stdout or None

    # -- packing -----------------------------------------------------------
    @staticmethod
    def to_rgb565(raw: bytes) -> bytes:
        from PIL import Image

        image = Image.open(io.BytesIO(raw))
        image = image.convert("RGB")
        # The Windows bridge stretches the thumbnail over a black 96x96 bitmap
        # (Graphics.DrawImage with an explicit destination rectangle), so match
        # that instead of letterboxing.
        image = image.resize((COVER_SIZE, COVER_SIZE), Image.BICUBIC)
        try:
            import numpy as np

            rgb = np.asarray(image, dtype=np.uint16)
            words = ((rgb[:, :, 0] & 0xF8) << 8) | ((rgb[:, :, 1] & 0xFC) << 3) | (
                rgb[:, :, 2] >> 3
            )
            return words.astype("<u2").tobytes()
        except ImportError:
            pass

        out = bytearray(COVER_BYTES)
        pixels = image.load()
        index = 0
        for y in range(COVER_SIZE):
            for x in range(COVER_SIZE):
                red, green, blue = pixels[x, y]
                word = ((red & 0xF8) << 8) | ((green & 0xFC) << 3) | (blue >> 3)
                out[index] = word & 0xFF
                out[index + 1] = (word >> 8) & 0xFF
                index += 2
        return bytes(out)


# --------------------------------------------------------------------------
# spectrum: capture the sink monitor and turn it into 32 bars
# --------------------------------------------------------------------------


class SpectrumCapture(threading.Thread):
    """PipeWire/PulseAudio loopback capture, mirroring ``audio_capture.cs``."""

    def __init__(self, source: str, on_bins, debug: bool = False, is_wanted=None) -> None:
        super().__init__(name="spectrum-capture", daemon=True)
        self.source = source
        self.on_bins = on_bins
        self.debug = debug
        # ``is_wanted`` lets the bridge pause the spectrum while nothing is
        # listening.  The capture stream stays open (that is nearly free), only
        # the FFT and the datagrams are skipped.
        self.is_wanted = is_wanted or (lambda: True)
        self.error = ""
        self.running = True
        self._proc: Optional[subprocess.Popen] = None
        self._smooth = [0.0] * SPECTRUM_BINS
        self._buffer: List[float] = []
        self._idle_ms = 0
        self.frames = 0

    # -- process plumbing --------------------------------------------------
    def stop(self) -> None:
        self.running = False
        self._kill()

    def _kill(self) -> None:
        proc = self._proc
        self._proc = None
        if proc and proc.poll() is None:
            try:
                proc.terminate()
                proc.wait(timeout=2.0)
            except Exception:  # noqa: BLE001
                try:
                    proc.kill()
                except Exception:  # noqa: BLE001
                    pass

    def _default_monitor(self) -> str:
        try:
            sink = subprocess.run(
                ["pactl", "get-default-sink"], capture_output=True, text=True, timeout=2.0
            ).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            sink = ""
        return (sink + ".monitor") if sink else "@DEFAULT_MONITOR@"

    def _command(self, source: str) -> List[str]:
        return [
            "parec",
            "--raw",
            "--format=s16le",
            "--rate=%d" % CAPTURE_RATE,
            "--channels=%d" % CAPTURE_CHANNELS,
            "--latency-msec=20",
            "--device=%s" % source,
        ]

    # -- main loop ---------------------------------------------------------
    def run(self) -> None:
        while self.running:
            source = self.source
            if source in ("auto", "", "@DEFAULT_MONITOR@"):
                source = self._default_monitor()
            if not shutil.which("parec"):
                self.error = "parec not found (install pulseaudio-utils)"
                log("spectrum disabled: %s", self.error)
                return
            try:
                self._proc = subprocess.Popen(
                    self._command(source),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    bufsize=0,
                )
                log("spectrum capture started on %s", source)
                self.error = ""
                self._read_stream()
            except Exception as exc:  # noqa: BLE001
                self.error = str(exc)
                log("spectrum capture failed: %s", exc)
            finally:
                self._kill()
            if self.running:
                time.sleep(2.0)

    def _read_stream(self) -> None:
        assert self._proc and self._proc.stdout
        stream = self._proc.stdout
        block = CAPTURE_CHANNELS * 2 * 480  # ~10 ms of s16le stereo
        while self.running:
            chunk = stream.read(block)
            if not chunk:
                break
            self._feed(chunk)

    def _feed(self, chunk: bytes) -> None:
        if not self.is_wanted():
            self._buffer.clear()
            if any(self._smooth):
                self._smooth = [0.0] * SPECTRUM_BINS
            return
        usable = len(chunk) - (len(chunk) % (CAPTURE_CHANNELS * 2))
        if usable <= 0:
            return
        samples = struct.unpack("<%dh" % (usable // 2), chunk[:usable])
        mono = [
            sum(samples[i:i + CAPTURE_CHANNELS]) / (32768.0 * CAPTURE_CHANNELS)
            for i in range(0, len(samples), CAPTURE_CHANNELS)
        ]
        self._buffer.extend(mono)
        self._idle_ms = 0
        while len(self._buffer) >= FFT_SIZE:
            block = self._buffer[:FFT_SIZE]
            bins = self._compute(block)
            self.frames += 1
            try:
                self.on_bins(bins)
            except Exception:  # noqa: BLE001
                pass
            del self._buffer[: FFT_SIZE - FFT_OVERLAP]

    # -- spectrum math (kept faithful to the C# implementation) ------------
    def _compute(self, block: List[float]) -> List[float]:
        try:
            powers = self._powers_numpy(block)
        except ImportError:
            powers = self._powers_goertzel(block)

        rms = math.sqrt(sum(value * value for value in block) / len(block))
        peak = max(powers) if powers else 0.0
        norm = max(peak * 0.85, rms * 1.2, 0.00002)

        result = []
        for index, value in enumerate(powers):
            raw = min(1.0, value / norm)
            raw = raw ** CURVE
            smoothed = self._smooth[index] * SMOOTH_KEEP + raw * SMOOTH_NEW
            smoothed = min(1.0, smoothed)
            self._smooth[index] = smoothed
            result.append(smoothed)
        return result

    def _band_edges(self) -> List[tuple]:
        edges = []
        for index in range(SPECTRUM_BINS):
            low = self._band_freq(index - 0.5)
            high = self._band_freq(index + 0.5)
            edges.append((low, high))
        return edges

    @staticmethod
    def _band_freq(position: float) -> float:
        position = clamp(position, 0.0, SPECTRUM_BINS - 1.0)
        ratio = position / float(SPECTRUM_BINS - 1)
        return SPECTRUM_MIN_HZ * math.pow(SPECTRUM_MAX_HZ / SPECTRUM_MIN_HZ, ratio)

    def _powers_numpy(self, block: List[float]) -> List[float]:
        import numpy as np

        samples = np.asarray(block, dtype=np.float64)
        magnitude = np.abs(np.fft.rfft(samples)) / len(samples)
        freqs = np.fft.rfftfreq(len(samples), 1.0 / CAPTURE_RATE)
        powers = []
        for low, high in self._band_edges():
            mask = (freqs >= low) & (freqs <= high)
            if not mask.any():
                index = int(round(low * len(samples) / CAPTURE_RATE))
                index = min(max(index, 0), len(magnitude) - 1)
                powers.append(float(magnitude[index]))
            else:
                powers.append(float(magnitude[mask].max()))
        return powers

    def _powers_goertzel(self, block: List[float]) -> List[float]:
        powers = []
        for index in range(SPECTRUM_BINS):
            ratio = float(index) / float(SPECTRUM_BINS - 1)
            freq = SPECTRUM_MIN_HZ * math.pow(SPECTRUM_MAX_HZ / SPECTRUM_MIN_HZ, ratio)
            omega = 2.0 * math.pi * freq / CAPTURE_RATE
            coeff = 2.0 * math.cos(omega)
            s1 = s2 = 0.0
            for sample in block:
                s0 = sample + coeff * s1 - s2
                s2 = s1
                s1 = s0
            power = s1 * s1 + s2 * s2 - coeff * s1 * s2
            powers.append(math.sqrt(power if power > 0 else 0.0) / len(block))
        return powers


# --------------------------------------------------------------------------
# websocket framing (server side, no external dependency)
# --------------------------------------------------------------------------


def ws_accept_key(client_key: str) -> str:
    import hashlib

    digest = hashlib.sha1(
        (client_key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")
    ).digest()
    return base64.b64encode(digest).decode("ascii")


def ws_frame(opcode: int, payload: bytes) -> bytes:
    header = bytearray([0x80 | opcode])
    length = len(payload)
    if length < 126:
        header.append(length)
    elif length < 65536:
        header.append(126)
        header += struct.pack(">H", length)
    else:
        header.append(127)
        header += struct.pack(">Q", length)
    return bytes(header) + payload


# --------------------------------------------------------------------------
# websocket client
# --------------------------------------------------------------------------


class WsClient:
    def __init__(self, writer: asyncio.StreamWriter, ip: str, loop: asyncio.AbstractEventLoop):
        self.writer = writer
        self.ip = ip
        self.loop = loop
        self.queue: asyncio.Queue = asyncio.Queue(maxsize=16)
        self.closed = False
        self.task = loop.create_task(self._drain())

    def send(self, frame: bytes) -> None:
        if self.closed:
            return
        try:
            self.queue.put_nowait(frame)
        except asyncio.QueueFull:
            # Never let a slow device stall the bridge; drop the oldest frame.
            try:
                self.queue.get_nowait()
            except asyncio.QueueEmpty:
                pass
            try:
                self.queue.put_nowait(frame)
            except asyncio.QueueFull:
                pass

    async def _drain(self) -> None:
        try:
            while True:
                frame = await self.queue.get()
                if frame is None:
                    break
                self.writer.write(frame)
                await self.writer.drain()
        except (ConnectionError, asyncio.CancelledError):
            pass
        except Exception:  # noqa: BLE001
            pass

    async def close(self) -> None:
        if self.closed:
            return
        self.closed = True
        try:
            self.writer.write(ws_frame(0x8, b""))
            await self.writer.drain()
        except Exception:  # noqa: BLE001
            pass
        self.task.cancel()


# --------------------------------------------------------------------------
# the bridge
# --------------------------------------------------------------------------


class Bridge:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.loop: Optional[asyncio.AbstractEventLoop] = None
        self.metrics = MetricsSampler(args.gpu)
        self.media = MprisMedia(args.player)
        self.cover = CoverBuilder(debug=args.verbose)
        self.spectrum: Optional[SpectrumCapture] = None
        self._stop: Optional[asyncio.Event] = None

        self.state: Dict[str, Any] = {
            "type": "state",
            "ts": 0,
            "cpu": 0,
            "gpu": 0,
            "mem": 0,
            "mem_used": None,
            "mem_total": None,
            "playing": False,
            "status": "NoSession",
            "title": "",
            "artist": "",
            "album": "",
            "app": "",
            "cover_version": 0,
            "cover_ready": True,
            "cover_error": "",
        }
        self.cover_data: Optional[bytes] = None
        self.cover_version = 0
        self._cover_token = 0
        self._last_track_key = ""

        self.spectrum_json = dumps({"type": "spectrum", "bins": []})
        self.spectrum_bytes = bytes(SPECTRUM_BINS)
        self.spectrum_sent = 0
        self.udp_sent = 0
        self._last_spectrum_sent = 0.0
        self._last_state_sent = 0.0
        self._last_state_key = ""
        self._last_metrics = 0.0
        self._clients: Dict[int, WsClient] = {}
        self._next_client_id = 1
        self._udp: Optional[socket.socket] = None
        # Any request (device polling /state, a WebSocket, curl) counts as an
        # audience; the spectrum pauses a few seconds after the last one leaves.
        self._last_client_seen = 0.0

    # -- lifecycle ---------------------------------------------------------
    async def run(self) -> None:
        self.loop = asyncio.get_running_loop()
        self._stop = asyncio.Event()
        if self.args.udp_port:
            self._open_udp()
        if not self.args.no_spectrum:
            self.spectrum = SpectrumCapture(
                self.args.spectrum_source,
                self._on_bins_threadsafe,
                self.args.verbose,
                self._spectrum_wanted,
            )
            self.spectrum.start()

        server = await asyncio.start_server(
            self._handle_client, self.args.bind, self.args.port, backlog=32
        )
        log("PC Overview bridge listening on %s:%d", self.args.bind, self.args.port)
        log("open http://localhost:%d/ to verify", self.args.port)
        hint = firewall_hint(self.args.port)
        if hint:
            log("warning: %s", hint)
        if self.args.udp_port and not self.args.no_udp_broadcast:
            log("spectrum UDP target port %d (unicast to clients, broadcast fallback)",
                self.args.udp_port)

        loop_task = asyncio.create_task(self._state_loop())
        try:
            async with server:
                await self._stop.wait()
        finally:
            loop_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await loop_task
            for client in list(self._clients.values()):
                await client.close()
            self._clients.clear()
        log("bridge stopped")

    def shutdown(self) -> None:
        if self.spectrum:
            self.spectrum.stop()
        if self._udp:
            try:
                self._udp.close()
            except OSError:
                pass

    def _open_udp(self) -> None:
        try:
            udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            udp.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            udp.setblocking(False)
            self._udp = udp
        except OSError as exc:
            log("udp socket failed: %s", exc)
            self._udp = None

    # -- state loop --------------------------------------------------------
    async def _state_loop(self) -> None:
        await self.loop.run_in_executor(None, self.metrics.sample)
        self._apply_metrics()
        while True:
            try:
                snapshot = await self.loop.run_in_executor(None, self.media.poll)
                self._apply_media(snapshot)
                now = time.monotonic()
                if now - self._last_metrics >= 1.0:
                    await self.loop.run_in_executor(None, self.metrics.sample)
                    self._apply_metrics()
                    self._last_metrics = now
                self._push_state()
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # noqa: BLE001
                log("state loop error: %s", exc)
            await asyncio.sleep(self.args.media_poll_ms / 1000.0)

    def _apply_metrics(self) -> None:
        self.state["cpu"] = round(self.metrics.cpu)
        self.state["gpu"] = round(self.metrics.gpu)
        self.state["mem"] = round(self.metrics.mem)
        self.state["mem_used"] = self.metrics.mem_used
        self.state["mem_total"] = self.metrics.mem_total

    def _apply_media(self, snapshot: Optional[Dict[str, Any]]) -> None:
        state = self.state
        if not snapshot:
            if self._last_track_key:
                self._last_track_key = ""
                # Bump the version so the device drops the stale cover instead of
                # leaving the last album on screen behind a "NO MUSIC" title.
                self.cover_version += 1
                state["cover_version"] = self.cover_version
                self._set_cover(None)
            state["playing"] = False
            state["status"] = "NoSession"
            state["title"] = ""
            state["artist"] = ""
            state["album"] = ""
            state["app"] = ""
            return

        state["playing"] = snapshot["playing"]
        state["status"] = snapshot["status"]
        state["title"] = snapshot["title"]
        state["artist"] = snapshot["artist"]
        state["album"] = snapshot["album"]
        state["app"] = snapshot["app"]

        if snapshot["key"] == self._last_track_key:
            return
        self._last_track_key = snapshot["key"]
        # New track: bump the version and keep the old cover on screen until the
        # new one is decoded (the device retries every 250 ms while ready=false).
        self.cover_version += 1
        state["cover_version"] = self.cover_version
        state["cover_ready"] = False
        art_url = snapshot["art_url"]
        track_url = snapshot["url"]
        if art_url or track_url.startswith("file://"):
            token = self.cover_version
            self.loop.run_in_executor(
                None, self._resolve_cover, art_url, track_url, token
            )
        else:
            self._set_cover(None)

    def _resolve_cover(self, art_url: str, track_url: str, token: int) -> None:
        data = self.cover.resolve(art_url, track_url)
        self.loop.call_soon_threadsafe(self._finish_cover, token, data)

    def _finish_cover(self, token: int, data: Optional[bytes]) -> None:
        if token != self.cover_version:
            return  # a newer track already won
        self.cover_data = data
        self.state["cover_ready"] = True
        self.state["cover_error"] = "" if data else self.cover.last_error

    def _set_cover(self, data: Optional[bytes]) -> None:
        self.cover_data = data
        self.state["cover_ready"] = True
        self.state["cover_error"] = "" if data else "no cover source"

    def _push_state(self) -> None:
        state = self.state
        key = "|".join(
            text(state.get(field))
            for field in (
                "title",
                "artist",
                "album",
                "app",
                "status",
                "playing",
                "cover_version",
                "cover_ready",
                "cpu",
                "gpu",
                "mem",
                "mem_used",
                "mem_total",
            )
        )
        now = time.monotonic()
        if key == self._last_state_key and now - self._last_state_sent < 1.0:
            return
        self._last_state_key = key
        self._last_state_sent = now
        state["ts"] = int(time.time())
        self._broadcast_text(dumps(state))

    # -- spectrum ----------------------------------------------------------
    def _spectrum_wanted(self) -> bool:
        if self.args.spectrum_always or self._clients:
            return True
        return (time.monotonic() - self._last_client_seen) < 10.0

    def _on_bins_threadsafe(self, bins: Sequence[float]) -> None:
        if self.loop is None:
            return
        self.loop.call_soon_threadsafe(self._on_bins, list(bins))

    def _on_bins(self, bins: Sequence[float]) -> None:
        values = [clamp(float(value), 0.0, 1.0) for value in bins]
        self.spectrum_json = dumps(
            {"type": "spectrum", "bins": [round(value, 3) for value in values]}
        )
        self.spectrum_bytes = bytes(int(round(value * 255.0)) for value in values)

        now = time.monotonic()
        if now - self._last_spectrum_sent < self.args.spectrum_interval:
            return
        self._last_spectrum_sent = now
        self.spectrum_sent += 1
        self._send_spectrum_udp(self.spectrum_bytes)
        self._broadcast_binary(self.spectrum_bytes)

    def _send_spectrum_udp(self, payload: bytes) -> None:
        if not self._udp:
            return
        targets = sorted({client.ip for client in self._clients.values() if client.ip})
        if targets:
            for ip in targets:
                try:
                    self._udp.sendto(payload, (ip, self.args.udp_port))
                    self.udp_sent += 1
                except OSError:
                    pass
            return
        if self.args.no_udp_broadcast:
            return
        try:
            self._udp.sendto(payload, ("255.255.255.255", self.args.udp_port))
            self.udp_sent += 1
        except OSError:
            pass

    def _broadcast_text(self, payload: str) -> None:
        if not self._clients:
            return
        frame = ws_frame(0x1, payload.encode("utf-8"))
        for client in list(self._clients.values()):
            client.send(frame)

    def _broadcast_binary(self, payload: bytes) -> None:
        if not self._clients:
            return
        frame = ws_frame(0x2, payload)
        for client in list(self._clients.values()):
            client.send(frame)

    # -- http --------------------------------------------------------------
    async def _handle_client(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        peer = writer.get_extra_info("peername")
        ip = peer[0] if peer else ""
        try:
            payload = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), timeout=15.0)
        except Exception:  # noqa: BLE001 - includes timeout and EOF
            await self._close(writer)
            return

        try:
            head, _, _ = payload.decode("latin-1").partition("\r\n\r\n")
            lines = [line for line in head.split("\r\n") if line]
            method, path = (lines[0].split(" ") + ["", ""])[:2]
            headers = {}
            for line in lines[1:]:
                name, _, value = line.partition(":")
                headers[name.strip().lower()] = value.strip()
        except Exception:  # noqa: BLE001
            await self._respond(writer, 400, "text/plain; charset=utf-8", b"bad request")
            return

        query = ""
        if "?" in path:
            path, _, query = path.partition("?")

        # Anything that looks like a device or a viewer keeps the spectrum
        # running; /health is a diagnostic endpoint and must not wake it up.
        if path != "/health":
            self._last_client_seen = time.monotonic()

        if headers.get("upgrade", "").lower() == "websocket" and path == "/ws":
            await self._serve_ws(reader, writer, headers, ip)
            return

        try:
            await self._serve_http(writer, method, path, query)
        finally:
            await self._close(writer)

    async def _serve_http(
        self, writer: asyncio.StreamWriter, method: str, path: str, query: str
    ) -> None:
        if method != "GET":
            await self._respond(writer, 405, "text/plain; charset=utf-8", b"method not allowed")
            return
        if path in ("/state",):
            body = dumps(self.state).encode("utf-8")
            await self._respond(writer, 200, "application/json; charset=utf-8", body)
            return
        if path == "/spectrum":
            await self._respond(
                writer, 200, "application/json; charset=utf-8", self.spectrum_json.encode("utf-8")
            )
            return
        if path == "/cover":
            if not self.cover_data:
                await self._respond(writer, 404, "text/plain; charset=utf-8", b"no cover")
                return
            await self._respond(
                writer,
                200,
                "application/octet-stream",
                self.cover_data,
                {"X-Cover-Version": str(self.cover_version)},
            )
            return
        if path == "/cover64":
            if not self.cover_data:
                await self._respond(writer, 404, "text/plain; charset=utf-8", b"no cover")
                return
            body = dumps(
                {
                    "ok": True,
                    "version": str(self.cover_version),
                    "data": base64.b64encode(self.cover_data).decode("ascii"),
                }
            ).encode("utf-8")
            await self._respond(writer, 200, "application/json; charset=utf-8", body)
            return
        if path == "/health":
            audio = bool(self.spectrum and self.spectrum.error == "")
            body = dumps(
                {
                    "ok": True,
                    "clients": len(self._clients),
                    "spectrum_sent": self.spectrum_sent,
                    "spectrum_active": self._spectrum_wanted(),
                    "spectrum_frames": self.spectrum.frames if self.spectrum else 0,
                    "udp_sent": self.udp_sent,
                    "audio": audio,
                    "audio_error": (self.spectrum.error[:300] if self.spectrum else ""),
                    "media_error": self.media.error[:300],
                }
            ).encode("utf-8")
            await self._respond(writer, 200, "application/json; charset=utf-8", body)
            return
        if path in ("/", ""):
            await self._respond(writer, 200, "text/html; charset=utf-8", self._index_html())
            return
        if path == "/salt-media-changed":
            # Kept for protocol parity with the Windows bridge; MPRIS needs no nudge.
            await self._respond(writer, 200, "application/json; charset=utf-8", b'{"ok":true}')
            return
        await self._respond(writer, 404, "text/plain; charset=utf-8", b"not found")

    def _index_html(self) -> bytes:
        return (
            "<!doctype html><meta charset=utf-8><title>HoloCubic PC Overview bridge</title>"
            "<style>body{font:14px/1.5 system-ui,sans-serif;margin:2rem;max-width:46rem}"
            "pre{background:#f4f4f4;padding:.8rem;border-radius:6px;overflow:auto}</style>"
            "<h1>HoloCubic PC Overview bridge</h1>"
            "<p>Linux bridge. Point the device app at this host and port.</p>"
            "<ul><li><a href=/state>/state</a></li><li><a href=/spectrum>/spectrum</a></li>"
            "<li><a href=/health>/health</a></li><li><a href=/cover64>/cover64</a></li></ul>"
            "<h2>/state</h2><pre id=state>loading...</pre>"
            "<script>"
            "async function tick(){try{const r=await fetch('/state');"
            "document.getElementById('state').textContent=JSON.stringify(await r.json(),null,2);}"
            "catch(e){document.getElementById('state').textContent=String(e);}}"
            "tick();setInterval(tick,1000);"
            "</script>"
        ).encode("utf-8")

    async def _respond(
        self,
        writer: asyncio.StreamWriter,
        status: int,
        content_type: str,
        body: bytes,
        extra: Optional[Dict[str, str]] = None,
    ) -> None:
        reason = {200: "OK", 400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed"}.get(
            status, "OK"
        )
        lines = [
            "HTTP/1.1 %d %s" % (status, reason),
            "Content-Type: %s" % content_type,
            "Content-Length: %d" % len(body),
            "Cache-Control: no-store",
            "Connection: close",
        ]
        for name, value in (extra or {}).items():
            lines.append("%s: %s" % (name, value))
        writer.write(("\r\n".join(lines) + "\r\n\r\n").encode("latin-1") + body)
        try:
            await writer.drain()
        except (ConnectionError, OSError):
            pass

    async def _close(self, writer: asyncio.StreamWriter) -> None:
        try:
            writer.close()
            await writer.wait_closed()
        except Exception:  # noqa: BLE001
            pass

    # -- websocket ---------------------------------------------------------
    async def _serve_ws(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
        headers: Dict[str, str],
        ip: str,
    ) -> None:
        key = headers.get("sec-websocket-key", "")
        if not key:
            await self._respond(writer, 400, "text/plain; charset=utf-8", b"missing key")
            await self._close(writer)
            return
        writer.write(
            (
                "HTTP/1.1 101 Switching Protocols\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                "Sec-WebSocket-Accept: %s\r\n\r\n" % ws_accept_key(key)
            ).encode("latin-1")
        )
        await writer.drain()

        client = WsClient(writer, ip, asyncio.get_running_loop())
        client_id = self._next_client_id
        self._next_client_id += 1
        self._clients[client_id] = client
        log("ws client %s connected (%d total)", ip or "?", len(self._clients))

        # Send the current state immediately so the device does not wait a tick.
        client.send(ws_frame(0x1, dumps(self.state).encode("utf-8")))
        if self.spectrum_bytes:
            client.send(ws_frame(0x2, self.spectrum_bytes))

        try:
            while True:
                opcode, data = await self._read_ws_frame(reader)
                if opcode == 0x8:
                    break
                if opcode == 0x9:
                    client.send(ws_frame(0xA, data))
        except (asyncio.IncompleteReadError, ConnectionError, asyncio.CancelledError):
            pass
        except Exception:  # noqa: BLE001
            pass
        finally:
            self._clients.pop(client_id, None)
            await client.close()
            await self._close(writer)
            log("ws client %s disconnected (%d left)", ip or "?", len(self._clients))

    @staticmethod
    async def _read_ws_frame(reader: asyncio.StreamReader) -> tuple:
        header = await reader.readexactly(2)
        opcode = header[0] & 0x0F
        masked = bool(header[1] & 0x80)
        length = header[1] & 0x7F
        if length == 126:
            length = struct.unpack(">H", await reader.readexactly(2))[0]
        elif length == 127:
            length = struct.unpack(">Q", await reader.readexactly(8))[0]
        mask = await reader.readexactly(4) if masked else b""
        data = await reader.readexactly(length) if length else b""
        if mask:
            data = bytes(byte ^ mask[index % 4] for index, byte in enumerate(data))
        return opcode, data


# --------------------------------------------------------------------------
# entry point
# --------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog=ARGV0,
        description="HoloCubic PC Overview bridge for Linux (MPRIS + PipeWire).",
    )
    parser.add_argument("--bind", default="0.0.0.0", help="HTTP bind address (default 0.0.0.0)")
    parser.add_argument("--port", type=int, default=8088, help="HTTP/WebSocket port (default 8088)")
    parser.add_argument("--udp-port", type=int, default=8090, help="spectrum UDP port (default 8090)")
    parser.add_argument("--no-udp-broadcast", action="store_true",
                        help="do not fall back to 255.255.255.255 when no client is connected")
    parser.add_argument("--no-spectrum", action="store_true", help="disable audio capture entirely")
    parser.add_argument("--spectrum-always", action="store_true",
                        help="capture and broadcast even with no client connected "
                             "(Windows behaviour; costs CPU and LAN broadcast)")
    parser.add_argument("--spectrum-source", default="auto",
                        help="parec device, e.g. 'auto' (default sink monitor) or a monitor name")
    parser.add_argument("--spectrum-interval", type=float, default=0.02,
                        help="minimum seconds between spectrum datagrams (default 0.02)")
    parser.add_argument("--media-poll-ms", type=int, default=100,
                        help="MPRIS poll interval in ms (default 100)")
    parser.add_argument("--player", default=None,
                        help="prefer a player whose bus name or identity contains this text")
    parser.add_argument("--gpu", default="auto",
                        help="GPU to report: 'auto' (busiest card) or a card name such as card1")
    parser.add_argument("--list-players", action="store_true",
                        help="print the MPRIS players visible right now and exit")
    parser.add_argument("--print-metrics", nargs="?", const=5.0, default=None, type=float,
                        metavar="SECONDS",
                        help="print CPU/GPU/RAM once per second for SECONDS (default 5) and exit")
    parser.add_argument("--verbose", action="store_true", help="extra logging")
    return parser


def print_metrics(args: argparse.Namespace) -> int:
    """Debug helper: show what the bridge would report for CPU/GPU/RAM."""
    sampler = MetricsSampler(args.gpu)
    print("gpu filter: %s" % args.gpu)
    sampler.sample()  # prime the /proc/stat delta
    end = time.time() + max(1.0, float(args.print_metrics))
    while time.time() < end:
        time.sleep(1.0)
        sampler.sample()
        memory = (
            "%4.1f/%4.1f GB" % (sampler.mem_used, sampler.mem_total)
            if sampler.mem_used is not None
            else "unavailable"
        )
        print(
            "cpu=%3.0f%%  gpu=%3.0f%%  mem=%3.0f%%  %s  [%s]"
            % (
                sampler.cpu,
                sampler.gpu,
                sampler.mem,
                memory,
                sampler.gpu_source or "no gpu source",
            )
        )
    return 0


def list_players() -> int:
    media = MprisMedia()
    if not media.connect():
        log("cannot reach the session bus: %s", media.error)
        return 1
    names = media._bus.list_names()
    found = [str(name) for name in names if str(name).startswith(MPRIS_PREFIX)]
    if not found:
        print("no MPRIS players are running")
        return 0
    for name in found:
        snapshot = media._read_player(name)
        if snapshot:
            print(
                "%-40s %-12s %s - %s"
                % (snapshot["bus"], snapshot["status"], snapshot["artist"], snapshot["title"])
            )
    return 0


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    if args.list_players:
        return list_players()
    if args.print_metrics is not None:
        return print_metrics(args)

    bridge = Bridge(args)
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)

    def request_stop(*_args: Any) -> None:
        stop = getattr(bridge, "_stop", None)
        if stop is not None and not stop.is_set():
            stop.set()
        else:
            loop.stop()

    for signal_name in ("SIGTERM", "SIGINT"):
        signum = getattr(signal, signal_name, None)
        if signum is None:
            continue
        try:
            loop.add_signal_handler(signum, request_stop)
        except NotImplementedError:
            pass

    try:
        loop.run_until_complete(bridge.run())
    except (KeyboardInterrupt, RuntimeError):
        pass
    finally:
        bridge.shutdown()
        try:
            loop.stop()
            loop.close()
        except Exception:  # noqa: BLE001
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())

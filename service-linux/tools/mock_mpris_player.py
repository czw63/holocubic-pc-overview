#!/usr/bin/env python3
"""A throwaway MPRIS2 player, useful for testing the bridge without a real player.

Usage::

    python3 mock_mpris_player.py [cover.png] [title] [artist] [album]

If ``cover.png`` is omitted a small gradient cover is generated in /tmp.  The
mock player registers ``org.mpris.MediaPlayer2.MockPlayer`` on the session bus
for 30 seconds, which is long enough for the device (or ``curl``) to see it.
"""

from __future__ import annotations

import os
import sys
import tempfile

import dbus
import dbus.mainloop.glib
import dbus.service
from gi.repository import GLib

BUS_NAME = "org.mpris.MediaPlayer2.MockPlayer"
PATH = "/org/mpris/MediaPlayer2"
PLAYER_IFACE = "org.mpris.MediaPlayer2.Player"
ROOT_IFACE = "org.mpris.MediaPlayer2"
PROPS_IFACE = "org.freedesktop.DBus.Properties"
LIFETIME_SECONDS = 30


def make_cover(path: str) -> None:
    from PIL import Image, ImageDraw

    size = 500
    image = Image.new("RGB", (size, size))
    draw = ImageDraw.Draw(image)
    for y in range(size):
        draw.line(
            [(0, y), (size, y)],
            fill=(int(255 * y / (size - 1)), 60, int(255 * (1 - y / (size - 1)))),
        )
    draw.ellipse([150, 150, 350, 350], fill=(255, 255, 255))
    draw.rectangle([0, 0, 60, 60], fill=(255, 0, 0))
    image.save(path)


class MockPlayer(dbus.service.Object):
    def __init__(self, bus_name, cover_url: str, title: str, artist: str, album: str):
        super().__init__(bus_name, PATH)
        self.props = {
            ROOT_IFACE: {
                "Identity": "Mock Player",
                "CanQuit": False,
                "DesktopEntry": "mock",
                "SupportedUriSchemes": dbus.Array([], signature="s"),
                "SupportedMimeTypes": dbus.Array([], signature="s"),
            },
            PLAYER_IFACE: {
                "PlaybackStatus": "Playing",
                "LoopStatus": "None",
                "Rate": 1.0,
                "Shuffle": False,
                "Volume": 1.0,
                "Position": dbus.Int64(1234),
                "CanSeek": False,
                "CanGoNext": False,
                "CanGoPrevious": False,
                "CanPlay": True,
                "CanPause": True,
                "Metadata": dbus.Dictionary(
                    {
                        "mpris:trackid": dbus.ObjectPath("/mock/track/1"),
                        "mpris:artUrl": cover_url,
                        "xesam:title": title,
                        "xesam:artist": dbus.Array([artist], signature="s"),
                        "xesam:album": album,
                        "xesam:url": "file:///tmp/mock-track.flac",
                    },
                    signature="sv",
                ),
            },
        }

    @dbus.service.method(PROPS_IFACE, in_signature="ss", out_signature="v")
    def Get(self, interface, prop):
        return self.props[interface][prop]

    @dbus.service.method(PROPS_IFACE, in_signature="s", out_signature="a{sv}")
    def GetAll(self, interface):
        return self.props.get(interface, {})

    @dbus.service.method(PROPS_IFACE, in_signature="ssv", out_signature="")
    def Set(self, interface, prop, value):
        self.props[interface][prop] = value

    @dbus.service.signal(PROPS_IFACE, signature="sa{sv}as")
    def PropertiesChanged(self, interface, changed, invalidated):
        pass

    @dbus.service.method(PLAYER_IFACE, in_signature="", out_signature="")
    def PlayPause(self):
        status = self.props[PLAYER_IFACE]["PlaybackStatus"]
        self.props[PLAYER_IFACE]["PlaybackStatus"] = "Paused" if status == "Playing" else "Playing"

    @dbus.service.method(PLAYER_IFACE, in_signature="", out_signature="")
    def Next(self):
        pass

    @dbus.service.method(ROOT_IFACE, in_signature="", out_signature="")
    def Raise(self):
        pass


def main() -> int:
    args = sys.argv[1:]
    cover_path = args[0] if args else os.path.join(tempfile.gettempdir(), "mock-cover.png")
    title = args[1] if len(args) > 1 else "Test Title"
    artist = args[2] if len(args) > 2 else "Test Artist"
    album = args[3] if len(args) > 3 else "Test Album"
    if not os.path.exists(cover_path):
        make_cover(cover_path)

    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    name = dbus.service.BusName(BUS_NAME, bus=bus)
    MockPlayer(name, "file://" + os.path.abspath(cover_path), title, artist, album)
    print("mock MPRIS player up: %s - %s (for %ds)" % (artist, title, LIFETIME_SECONDS), flush=True)

    loop = GLib.MainLoop()
    GLib.timeout_add_seconds(LIFETIME_SECONDS, lambda: (loop.quit(), False)[1])
    loop.run()
    print("mock MPRIS player down", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())

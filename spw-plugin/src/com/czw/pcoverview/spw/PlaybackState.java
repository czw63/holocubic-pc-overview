package com.czw.pcoverview.spw;

import com.xuncorp.spw.workshop.api.PlaybackExtensionPoint;

public final class PlaybackState {
    public static volatile PlaybackExtensionPoint.MediaItem media;
    public static volatile boolean playing;
    public static volatile String state = "Idle";
    public static volatile long position;

    private PlaybackState() {
    }

    public static void reset() {
        media = null;
        playing = false;
        state = "Idle";
        position = 0L;
    }
}

package com.czw.pcoverview.spw;

import com.xuncorp.spw.workshop.api.PlaybackExtensionPoint;
import org.pf4j.Extension;

@Extension
public final class SpwPlaybackExtension implements PlaybackExtensionPoint {
    @Override
    public void onStateChanged(State state) {
        PlaybackState.state = state == null ? "Idle" : state.name();
        PluginLog.log("onStateChanged " + PlaybackState.state);
    }

    @Override
    public void onIsPlayingChanged(boolean isPlaying) {
        PlaybackState.playing = isPlaying;
        PluginLog.log("onIsPlayingChanged " + isPlaying);
        BridgeNotifier.mediaChanged();
    }

    @Override
    public void onSeekTo(long position) {
        PlaybackState.position = Math.max(0L, position);
        PluginLog.log("onSeekTo " + PlaybackState.position);
    }

    @Override
    public String updateLyrics(MediaItem mediaItem) {
        return onBeforeLoadLyrics(mediaItem);
    }

    @Override
    public String onBeforeLoadLyrics(MediaItem mediaItem) {
        PlaybackState.media = mediaItem;
        PlaybackState.position = 0L;
        PluginLog.log("onBeforeLoadLyrics path=" +
            (mediaItem == null ? "" : mediaItem.getPath()) +
            " title=" + (mediaItem == null ? "" : mediaItem.getTitle()));
        BridgeNotifier.mediaChanged();
        return null;
    }

    @Override
    public String onAfterLoadLyrics(MediaItem mediaItem) {
        return null;
    }

    @Override
    public void onLyricsLineUpdated(LyricsLine lyricsLine) {
    }

    @Override
    public void onPositionUpdated(long position) {
        PlaybackState.position = Math.max(0L, position);
        PluginLog.log("onPositionUpdated " + PlaybackState.position);
    }
}

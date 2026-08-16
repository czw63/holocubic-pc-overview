package com.xuncorp.spw.workshop.api;

import org.pf4j.ExtensionPoint;

public interface PlaybackExtensionPoint extends ExtensionPoint {
    enum State {
        Idle,
        Buffering,
        Ready,
        Ended
    }

    final class MediaItem {
        private final String title;
        private final String artist;
        private final String album;
        private final String albumArtist;
        private final String path;

        public MediaItem(String title, String artist, String album, String albumArtist, String path) {
            this.title = title == null ? "" : title;
            this.artist = artist == null ? "" : artist;
            this.album = album == null ? "" : album;
            this.albumArtist = albumArtist == null ? "" : albumArtist;
            this.path = path == null ? "" : path;
        }

        public String getTitle() {
            return title;
        }

        public String getArtist() {
            return artist;
        }

        public String getAlbum() {
            return album;
        }

        public String getAlbumArtist() {
            return albumArtist;
        }

        public String getPath() {
            return path;
        }
    }

    final class LyricsLine {
        private final String mainText;

        public LyricsLine(String mainText) {
            this.mainText = mainText == null ? "" : mainText;
        }

        public String getPureMainText() {
            return mainText;
        }
    }

    default void onStateChanged(State state) {
    }

    default void onIsPlayingChanged(boolean isPlaying) {
    }

    default void onSeekTo(long position) {
    }

    default String updateLyrics(MediaItem mediaItem) {
        return null;
    }

    default String onBeforeLoadLyrics(MediaItem mediaItem) {
        return null;
    }

    default String onAfterLoadLyrics(MediaItem mediaItem) {
        return null;
    }

    default void onLyricsLineUpdated(LyricsLine lyricsLine) {
    }

    default void onPositionUpdated(long position) {
    }
}

package com.czw.pcoverview.spw;

import java.io.File;
import java.lang.reflect.Method;

public final class CoverExtractor {
    private CoverExtractor() {
    }

    public static byte[] extract(String path) {
        if (path == null || path.isEmpty()) {
            return null;
        }
        byte[] fromTags = extractWithJAudioTagger(path);
        if (fromTags != null) {
            PluginLog.log("cover from jaudiotagger bytes=" + fromTags.length);
            return fromTags;
        }
        return null;
    }

    private static byte[] extractWithJAudioTagger(String path) {
        try {
            Class<?> audioFileIO = Class.forName("org.jaudiotagger.audio.AudioFileIO");
            Method read = audioFileIO.getMethod("read", File.class);
            Object audioFile = read.invoke(null, new File(path));
            Method getTag = audioFile.getClass().getMethod("getTag");
            Object tag = getTag.invoke(audioFile);
            if (tag == null) {
                return null;
            }
            Method getFirstArtwork = tag.getClass().getMethod("getFirstArtwork");
            Object artwork = getFirstArtwork.invoke(tag);
            if (artwork == null) {
                return null;
            }
            Method getBinaryData = artwork.getClass().getMethod("getBinaryData");
            Object data = getBinaryData.invoke(artwork);
            return data instanceof byte[] ? (byte[]) data : null;
        } catch (Throwable error) {
            PluginLog.log("jaudiotagger cover failed: " + error);
            return null;
        }
    }
}

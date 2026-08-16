# Salt Player for Windows Integration

## What the SPW Workshop API Exposes

The official `spw-workshop-api` exposes a playback extension point with:

- Current media metadata: title, artist, album, album artist
- The full path of the current audio file
- Playback callbacks: state, playing/paused, seek, position
- Playback control: play, pause, next, previous, seek

It does not expose the decoded PCM stream or SPW's internal FFT data.

## Can We Grab SPW's Built-in Spectrum?

SPW has an internal `AudioVisualizerPipeline` with `fftData` and
`updateFftData`, but those classes are not part of the public workshop API and
are not guaranteed to be reachable from a plugin. Relying on internal
reflection would be fragile and may stop working after any SPW update.

The stable replacement is Windows process-loopback capture. Since SPW renders
audio through its own process tree, the bridge can capture exactly that
process with `AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK` and compute the
spectrum itself. This is already implemented in the bridge.

## Future Option: Decode the Current File

The workshop API does expose `MediaItem.path`. A plugin can publish that path
over HTTP, and the bridge could decode the file with `ffmpeg` to get a
spectrum that is completely independent of system audio. That approach is
more complex because it must follow the current playback position, so process
loopback is the preferred default for now.

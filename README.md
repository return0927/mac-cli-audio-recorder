# audio-relay

Records whatever you are hearing (on AirPods, an audio interface, or any other output) to an audio file, either from the whole system or from specific apps.

It uses Core Audio **process taps** (macOS 14.4+). You don't need BlackHole or a Multi-Output Device. Your output device doesn't change and volume keys keep working.

## Install

```bash
make install        # → ~/.local/bin/audio-relay
```

## Usage

```bash
audio-relay list                         # apps that are playing audio right now (--all for every app)
audio-relay record                       # record the whole system, Ctrl+C to stop → recording-<timestamp>.m4a
audio-relay record --app chrome -o lecture.m4a
audio-relay record -a Zoom -a Slack -d 3600 -o meeting.wav
audio-relay record --wait --app spotify -o song.m4a   # start recording once sound is detected
```

- `--wait` (`-w`): stays in standby until sound shows up, then starts recording. The 0.5 s just before the trigger is kept too, so the start isn't cut off.
  - `--threshold <dB>`: detection level (default `-50`). Set it higher, e.g. `-40`, to react only to louder sound.
  - `--pre-roll <seconds>`: how much audio before the trigger to keep (default `0.5`, `0` disables it).
  - `--duration` counts from when recording actually starts. If nothing is detected before you press Ctrl+C, no file is created.

- The output format comes from the file extension: `.m4a` (AAC 256 kbps, default), `.wav`/`.aiff`/`.caf` (24-bit PCM)
- `--app` takes a case-insensitive substring of the app name or bundle ID, or a PID. Helper processes (Chrome Helper, the WebKit GPU process, ...) are included automatically, and helpers that start during recording are added too.

## Permission

On first run, macOS asks for the **System Audio Recording** permission for the terminal app you ran it from. If the recording is silent, check
System Settings → Privacy & Security → Screen & System Audio Recording → **System Audio Recording Only** and allow your terminal app there.

## How it works

1. `CATapDescription` (unmuted) + `AudioHardwareCreateProcessTap`: a tap that copies the audio of the whole system or of the chosen processes
2. A private aggregate device that contains only that tap. No real device is added on purpose: adding AirPods would also turn on their mic and drop them into headset (low-quality) mode.
3. An IOProc writes the buffers to an `AVAudioFile`

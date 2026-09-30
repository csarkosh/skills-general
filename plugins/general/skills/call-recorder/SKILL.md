---
name: call-recorder
description: Use when the user wants to record a call or meeting so it can be transcribed ("record my Zoom call", "record this meeting"), to transcribe a voice memo, phone recording or other audio file ("transcribe this recording"), or to take notes from a meeting recording. macOS on Apple Silicon; transcription runs locally.
---

# Record and transcribe calls, locally

One script, `scripts/callrec.py` in this skill's directory, the folder that holds this
`SKILL.md`. It records a call on macOS as two tracks, the far side and your mic, then
transcribes both with Whisper on the machine and merges them into speaker-labelled turns.
It also transcribes a single mixed recording, such as a phone voice memo. Nothing is
uploaded.

## Consent first

Many US states, California among them, require **every party** to consent to a recording.
Get the consent on the tape: start recording, then ask ("Is it OK if I record this so I can
take notes?"). If anyone says no, stop and delete the files.

## Requirements

- **macOS on Apple Silicon** (mlx-whisper runs on Apple's MLX; recording uses avfoundation).
- **ffmpeg**: `brew install ffmpeg`.
- **Python 3.9+ with [`mlx-whisper`](https://pypi.org/project/mlx-whisper/)** for the two
  transcribe commands. Put it in a venv and run the script with that venv's Python:

  ```bash
  python3 -m venv ~/.venvs/whisper && ~/.venvs/whisper/bin/pip install mlx-whisper
  ```

  Recording (`devices`, `start`, `stop`, `status`) needs only the standard library. The first
  transcription downloads the model (about 1.6 GB) to the Hugging Face cache.
- **BlackHole 2ch**, for two-track call recording only (setup below).

## One-time setup for call recording

1. `brew install blackhole-2ch`.
2. Restart Core Audio instead of rebooting: `sudo killall coreaudiod` **in a real terminal**.
   It needs a TTY for the password, so it fails from an agent's non-interactive shell; ask the
   user to run it.
3. In **Audio MIDI Setup**, click **+** > **Create Multi-Output Device**. Tick your speakers
   or headphones and **BlackHole 2ch**. Set the primary device to the speakers or headphones,
   and tick **Drift Correction** on BlackHole.
4. Check the names with `callrec.py devices`.

On each call, set the meeting app's **speaker** to the Multi-Output Device and leave its
**microphone** as your real mic. The volume keys do nothing while a Multi-Output Device is
the output; set the level in the meeting app. Headphones give cleaner separation, because
the mic does not pick up the far side. The first recording may trigger a microphone
permission prompt for the terminal.

## Commands

```bash
PY=~/.venvs/whisper/bin/python        # any python3 works for recording
S=<this skill's directory>/scripts
$PY $S/callrec.py devices                         # list audio input devices
$PY $S/callrec.py start ~/calls/2026-01-02-intro  # records in the background, returns at once
$PY $S/callrec.py status
$PY $S/callrec.py stop                            # finalizes the files
$PY $S/callrec.py transcribe ~/calls/2026-01-02-intro --them-label "Alex" --me-label "Me"
$PY $S/callrec.py transcribe-file ~/Downloads/voice-memo.m4a
```

| Setting | Flag | Environment | Default |
|---|---|---|---|
| Far-side device | `start --them-device` | `CALLREC_THEM_DEVICE` | `BlackHole 2ch` |
| Your mic | `start --me-device` | `CALLREC_ME_DEVICE` | first device named "Microphone", else the first that is not BlackHole |
| Whisper model | `--model` | `CALLREC_MODEL` | `mlx-community/whisper-large-v3-turbo` |
| Language | `--language` | | `en` |

## Output

| File | What |
|---|---|
| `OUT_DIR/them.m4a`, `OUT_DIR/me.m4a` | The two tracks, mono AAC |
| `OUT_DIR/meta.json` | Each track's wall-clock start and device, used to align them |
| `OUT_DIR/ffmpeg-*.log` | ffmpeg's warnings; read these when a start fails |
| `OUT_DIR/transcript.md` | Speaker-labelled turns with `[mm:ss]` stamps |
| `<name>.transcript.md` | From `transcribe-file`, beside the input: timestamped lines, no speakers |

`start` refuses an `OUT_DIR` that already holds tracks, so use a new folder per call. The
recording state lives in `~/.cache/callrec/state.json`.

## Recording on a phone instead

Record on the phone with the call on speaker, then run `transcribe-file` on the audio:

- **iPhone Voice Memos**: share the memo to the Mac as `.m4a`.
- **Android Recorder**: its export is a zip holding the `.m4a` plus a `.txt` transcript with
  speaker labels. Whisper's wording was more accurate in testing ("heart rate" where Recorder
  heard "heartbreak"), so combine Whisper's text with Recorder's speaker labels.

## Why it works this way

- **One ffmpeg per device.** A single ffmpeg reading two live avfoundation inputs dropped
  about 4.7 s of audio mid-sentence from one track.
- **Word timestamps.** Without them, segment starts snap to 0 across leading silence and the
  two tracks misalign.
- **Loudness gate.** Whisper confidently invents whole sentences on near-silent audio, with
  the same confidence as real speech; only loudness tells them apart. A segment is kept only
  when its audio sits clearly above the track's noise floor: 15 dB for the two-track mic,
  which also drops the far side bleeding into the mic, and 8 dB for `transcribe-file`,
  because a phone hears the far side through a speaker only 12 to 16 dB over the floor.
  The script prints how many segments it dropped.

## Check the transcript

It is machine transcription. Check names, numbers, dates and amounts against the audio before
relying on them or sending notes to anyone.

Unit tests, from this skill's directory:
`python3 -B -m unittest discover -s scripts/tests` (`scripts/tests/test_callrec.py`).

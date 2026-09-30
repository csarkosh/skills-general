#!/usr/bin/env python3
"""Record a call on macOS as two tracks (the far side via BlackHole, you via the
mic) and transcribe it locally with speaker labels. Or transcribe one mixed
recording, such as a phone voice memo.

    callrec.py devices                             # list avfoundation audio devices
    callrec.py start OUT_DIR [--them-device NAME] [--me-device NAME]
    callrec.py stop                                # finalizes the files
    callrec.py status
    callrec.py transcribe OUT_DIR [--them-label NAME] [--me-label NAME]
    callrec.py transcribe-file PATH                # one mixed recording, no speaker labels

Recording needs ffmpeg and the meeting app's speaker set to a Multi-Output
Device (speakers or headphones + BlackHole 2ch). Transcription needs
mlx-whisper (Apple Silicon) and runs locally; nothing is uploaded.

Environment:
    CALLREC_THEM_DEVICE  far-side input device   (default "BlackHole 2ch")
    CALLREC_ME_DEVICE    your microphone          (default: first device named
                         "Microphone", else the first that is not the far-side one)
    CALLREC_MODEL        Whisper model            (default mlx-community/whisper-large-v3-turbo)

Setup and gotchas: SKILL.md, one directory above this file.
"""
import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

DEFAULT_THEM_DEVICE = "BlackHole 2ch"
DEFAULT_MODEL = "mlx-community/whisper-large-v3-turbo"
STATE = Path.home() / ".cache" / "callrec" / "state.json"
INSTALL_HINT = ("mlx-whisper is not installed for this Python ({}). Install it in a venv:\n"
                "  python3 -m venv ~/.venvs/whisper && ~/.venvs/whisper/bin/pip install mlx-whisper\n"
                "then run this script with ~/.venvs/whisper/bin/python.")

# Margins over the track's noise floor that a Whisper segment must clear to be kept.
TWO_TRACK_MARGIN_DB = 15.0  # a dedicated mic: also drops far-side bleed into the mic
MIXED_MARGIN_DB = 8.0       # one phone hears the far side only ~12-16 dB over the floor


def _need_ffmpeg():
    if not shutil.which("ffmpeg"):
        sys.exit("ffmpeg is not installed: brew install ffmpeg")


# ---------- devices ----------

def parse_audio_devices(text):
    """Audio device names, in index order, from `ffmpeg -f avfoundation -list_devices true` stderr."""
    names, in_audio = [], False
    for ln in text.splitlines():
        if "AVFoundation audio devices" in ln:
            in_audio = True
        elif "AVFoundation video devices" in ln:
            in_audio = False
        elif in_audio:
            m = re.search(r"\]\s*\[(\d+)\]\s*(.+?)\s*$", ln)
            if m:
                names.append(m.group(2))
    return names


def list_audio_devices():
    _need_ffmpeg()
    r = subprocess.run(["ffmpeg", "-hide_banner", "-f", "avfoundation", "-list_devices", "true", "-i", ""],
                       capture_output=True, text=True)
    return parse_audio_devices(r.stderr)


def pick_me_device(devices, them_device):
    """The first device named like a microphone, else the first that is not the far-side device."""
    others = [d for d in devices if d != them_device and "blackhole" not in d.lower()]
    for d in others:
        if "microphone" in d.lower():
            return d
    return others[0] if others else None


def devices_cmd():
    names = list_audio_devices()
    if not names:
        sys.exit("No avfoundation audio devices found (is this macOS?).")
    for i, n in enumerate(names):
        print(f"[{i}] {n}")


# ---------- recording ----------

def _load_state():
    try:
        return json.loads(STATE.read_text())
    except (FileNotFoundError, ValueError):
        return None


def _alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def _recording(st):
    return bool(st) and any(_alive(p) for p in st["pids"])


def start(out_dir, them_device, me_device):
    if sys.platform != "darwin":
        sys.exit("Recording uses macOS avfoundation; on other systems record elsewhere and use transcribe-file.")
    st = _load_state()
    if _recording(st):
        sys.exit(f"Already recording into {st['out_dir']}. Run `stop` first.")
    devices = list_audio_devices()
    if them_device not in devices:
        sys.exit(f"No audio device named {them_device!r}. Found: {devices}. "
                 "Install BlackHole (brew install blackhole-2ch) or pass --them-device.")
    if not me_device:
        me_device = pick_me_device(devices, them_device)
        if not me_device:
            sys.exit(f"No microphone found among {devices}; pass --me-device.")
    elif me_device not in devices:
        sys.exit(f"No audio device named {me_device!r}. Found: {devices}.")
    out = Path(out_dir).expanduser().resolve()
    out.mkdir(parents=True, exist_ok=True)
    tracks = {"them": them_device, "me": me_device}
    for name in tracks:
        if (out / f"{name}.m4a").exists():
            sys.exit(f"{out / name}.m4a already exists; pick a new OUT_DIR so nothing is overwritten.")
    # One ffmpeg per device: a single ffmpeg reading two live avfoundation
    # inputs dropped ~4.7 s of audio mid-sentence from one track in testing.
    procs, starts = {}, {}
    for name, device in tracks.items():
        cmd = ["ffmpeg", "-hide_banner", "-loglevel", "warning", "-nostdin",
               "-thread_queue_size", "2048", "-f", "avfoundation", "-i", f":{device}",
               "-ac", "1", "-c:a", "aac", "-b:a", "96k", str(out / f"{name}.m4a")]
        log = open(out / f"ffmpeg-{name}.log", "w")
        starts[name] = time.time()
        procs[name] = subprocess.Popen(cmd, stdout=log, stderr=log, start_new_session=True)
    time.sleep(2)
    dead = [n for n, p in procs.items() if p.poll() is not None]
    if dead:
        for p in procs.values():
            if p.poll() is None:
                p.send_signal(signal.SIGINT)
        sys.exit(f"ffmpeg for {', '.join(dead)} exited immediately; see ffmpeg-*.log in {out} "
                 "(microphone permission for this terminal is the usual cause).")
    # Each track's wall-clock start, so transcribe can align them on one clock.
    (out / "meta.json").write_text(json.dumps({"starts": starts, "devices": tracks}))
    STATE.parent.mkdir(parents=True, exist_ok=True)
    STATE.write_text(json.dumps({"pids": [p.pid for p in procs.values()],
                                 "out_dir": str(out), "started": min(starts.values())}))
    print(f"Recording -> them.m4a ({them_device}) + me.m4a ({me_device}) in {out}")


def stop():
    st = _load_state()
    if not _recording(st):
        STATE.unlink(missing_ok=True)
        sys.exit("Not recording.")
    for pid in st["pids"]:
        if _alive(pid):
            os.kill(pid, signal.SIGINT)  # ffmpeg finalizes the file on SIGINT
    for _ in range(50):
        if not any(_alive(p) for p in st["pids"]):
            break
        time.sleep(0.2)
    STATE.unlink(missing_ok=True)
    mins = (time.time() - st["started"]) / 60
    print(f"Stopped after {mins:.1f} min. Files in {st['out_dir']}")


def status():
    st = _load_state()
    if _recording(st):
        print(f"Recording for {(time.time() - st['started']) / 60:.1f} min into {st['out_dir']}")
    else:
        print("Not recording.")


# ---------- transcription ----------

def stamp(sec):
    m, s = divmod(int(sec), 60)
    h, m = divmod(m, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"


def parse_astats(text):
    """(times, rms_db) per frame from ffmpeg astats + ametadata=print output."""
    times, levels, t = [], [], None
    for ln in text.splitlines():
        if "pts_time:" in ln:
            t = float(ln.rsplit("pts_time:", 1)[1].split()[0])
        elif "RMS_level=" in ln and t is not None:
            v = ln.rsplit("=", 1)[1].strip()
            times.append(t)
            levels.append(-120.0 if v in ("-inf", "inf", "nan") else max(float(v), -120.0))
    return times, levels


def loudness(path):
    """(times, rms_db) per ~21 ms frame, via ffmpeg astats."""
    cmd = ["ffmpeg", "-hide_banner", "-nostats", "-i", str(path), "-af",
           "astats=metadata=1:reset=1,ametadata=print:key=lavfi.astats.Overall.RMS_level",
           "-f", "null", "-"]
    return parse_astats(subprocess.run(cmd, capture_output=True, text=True).stderr)


def speech_gate(times, levels, margin_db=TWO_TRACK_MARGIN_DB):
    """Return a check(start, end) that is True when the span holds audio well above
    the track's noise floor. Whisper confidently invents text on near-silent
    stretches: in testing a hallucinated sentence scored like real speech, but its
    audio peaked ~10 dB over the floor while real speech sat ~20 dB over."""
    if not levels:
        return lambda a, b: True
    floor = sorted(levels)[len(levels) // 5]  # 20th percentile ~ background noise
    def check(a, b):
        span = sorted(v for t, v in zip(times, levels) if a <= t <= b)
        if not span:
            return False
        return span[int(len(span) * 0.9)] >= floor + margin_db
    return check


def kept_segments(segments, is_speech):
    """(start, text) for segments with real speech, and how many were dropped."""
    kept, dropped = [], 0
    for s in segments:
        text = s["text"].strip()
        words = s.get("words") or []
        begin = words[0]["start"] if words else s["start"]
        end = words[-1]["end"] if words else s["end"]
        if not text or s.get("no_speech_prob", 0) >= 0.6 or not is_speech(begin, end):
            dropped += 1
            continue
        kept.append((begin, text))
    return kept, dropped


def merge_turns(segs):
    """Sort (start, label, text) lines and merge consecutive lines from one speaker into turns."""
    turns = []
    for start_s, label, text in sorted(segs):
        if turns and turns[-1][1] == label:
            turns[-1][2].append(text)
        else:
            turns.append([start_s, label, [text]])
    return [(s, label, " ".join(texts)) for s, label, texts in turns]


def _whisper():
    try:
        import mlx_whisper
    except ImportError:
        sys.exit(INSTALL_HINT.format(sys.executable))
    _need_ffmpeg()
    return mlx_whisper


def _run_whisper(mlx_whisper, path, model, language):
    # word_timestamps: segment starts otherwise snap to 0 across leading silence.
    return mlx_whisper.transcribe(str(path), path_or_hf_repo=model, language=language,
                                  condition_on_previous_text=False, word_timestamps=True)


def transcribe(out_dir, them_label, me_label, model, language):
    mlx_whisper = _whisper()
    out = Path(out_dir).expanduser().resolve()
    try:
        starts = json.loads((out / "meta.json").read_text())["starts"]
    except (FileNotFoundError, ValueError, KeyError):
        starts = {}
    t0 = min(starts.values()) if starts else 0.0
    segs = []
    for name, label in (("them", them_label), ("me", me_label)):
        f = out / f"{name}.m4a"
        if not f.exists():
            sys.exit(f"Missing {f}")
        offset = starts.get(name, t0) - t0  # align the two tracks on one clock
        r = _run_whisper(mlx_whisper, f, model, language)
        kept, dropped = kept_segments(r["segments"], speech_gate(*loudness(f)))
        segs += [(begin + offset, label, text) for begin, text in kept]
        if dropped:
            print(f"{name}: dropped {dropped} segment(s) with no audible speech (likely hallucinations)")
    turns = merge_turns(segs)
    md = [f"# Call transcript\n\nTracks: `them.m4a` = {them_label}, `me.m4a` = {me_label}. "
          "Machine transcription (Whisper); check numbers against the audio.\n"]
    md += [f"**[{stamp(s)}] {label}:** {text}\n" for s, label, text in turns]
    dest = out / "transcript.md"
    dest.write_text("\n".join(md))
    print(f"Wrote {dest} ({len(turns)} turns)")


def transcribe_file(path, model, language):
    """One mixed recording (e.g. a phone voice memo): timestamped, no speaker labels."""
    mlx_whisper = _whisper()
    f = Path(path).expanduser().resolve()
    if not f.exists():
        sys.exit(f"Missing {f}")
    r = _run_whisper(mlx_whisper, f, model, language)
    # A phone on the desk hears the far side through the speakers at only ~12-16 dB
    # over the room floor (the near voice ~21-28 dB), so the two-track 15 dB margin
    # drops real speech here. 8 dB kept every real line in testing.
    kept, dropped = kept_segments(r["segments"], speech_gate(*loudness(f), margin_db=MIXED_MARGIN_DB))
    md = [f"# Transcript: {f.name}\n\nSingle mixed track (no speaker labels). "
          "Machine transcription (Whisper); check numbers against the audio.\n"]
    md += [f"**[{stamp(begin)}]** {text}\n" for begin, text in kept]
    dest = f.with_name(f.stem + ".transcript.md")
    dest.write_text("\n".join(md))
    if dropped:
        print(f"dropped {dropped} segment(s) with no audible speech (likely hallucinations)")
    print(f"Wrote {dest} ({len(kept)} segments)")


def main():
    ap = argparse.ArgumentParser(description="Record a call as two tracks and transcribe it locally.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("devices", help="list avfoundation audio devices")
    a = sub.add_parser("start", help="start recording in the background")
    a.add_argument("out_dir")
    a.add_argument("--them-device", default=os.environ.get("CALLREC_THEM_DEVICE", DEFAULT_THEM_DEVICE))
    a.add_argument("--me-device", default=os.environ.get("CALLREC_ME_DEVICE"))
    sub.add_parser("stop", help="stop recording and finalize the files")
    sub.add_parser("status", help="say whether a recording is running")
    model_help = f"Whisper model (default $CALLREC_MODEL or {DEFAULT_MODEL})"
    t = sub.add_parser("transcribe", help="transcribe a two-track recording with speaker labels")
    t.add_argument("out_dir")
    t.add_argument("--them-label", default="Them")
    t.add_argument("--me-label", default="Me")
    tf = sub.add_parser("transcribe-file", help="transcribe one mixed recording, no speaker labels")
    tf.add_argument("path")
    for p in (t, tf):
        p.add_argument("--model", default=os.environ.get("CALLREC_MODEL", DEFAULT_MODEL), help=model_help)
        p.add_argument("--language", default="en")
    args = ap.parse_args()
    if args.cmd == "devices":
        devices_cmd()
    elif args.cmd == "start":
        start(args.out_dir, args.them_device, args.me_device)
    elif args.cmd == "stop":
        stop()
    elif args.cmd == "status":
        status()
    elif args.cmd == "transcribe":
        transcribe(args.out_dir, args.them_label, args.me_label, args.model, args.language)
    else:
        transcribe_file(args.path, args.model, args.language)


if __name__ == "__main__":
    main()

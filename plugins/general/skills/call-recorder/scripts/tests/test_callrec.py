"""Tests for callrec.py's pure helpers. No audio devices, no ffmpeg, no mlx-whisper.

Run, from this skill's directory: python3 -B -m unittest discover -s scripts/tests
"""

import importlib.util
import unittest
from pathlib import Path

_spec = importlib.util.spec_from_file_location("callrec", Path(__file__).resolve().parents[1] / "callrec.py")
callrec = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(callrec)

LIST_DEVICES = """\
[AVFoundation indev @ 0x1] AVFoundation video devices:
[AVFoundation indev @ 0x1] [0] FaceTime HD Camera
[AVFoundation indev @ 0x1] [1] Capture screen 0
[AVFoundation indev @ 0x1] AVFoundation audio devices:
[AVFoundation indev @ 0x1] [0] BlackHole 2ch
[AVFoundation indev @ 0x1] [1] External Microphone
[AVFoundation indev @ 0x1] [2] USB Audio Device
Error opening input file .
"""


class Devices(unittest.TestCase):
    def test_parses_only_audio_devices_in_order(self):
        self.assertEqual(callrec.parse_audio_devices(LIST_DEVICES),
                         ["BlackHole 2ch", "External Microphone", "USB Audio Device"])

    def test_prefers_a_microphone(self):
        self.assertEqual(callrec.pick_me_device(["BlackHole 2ch", "USB Audio Device", "External Microphone"],
                                                "BlackHole 2ch"), "External Microphone")

    def test_falls_back_to_first_device_that_is_not_the_far_side(self):
        self.assertEqual(callrec.pick_me_device(["BlackHole 2ch", "USB Audio Device"], "BlackHole 2ch"),
                         "USB Audio Device")

    def test_none_when_only_the_far_side_exists(self):
        self.assertIsNone(callrec.pick_me_device(["BlackHole 2ch"], "BlackHole 2ch"))


class Loudness(unittest.TestCase):
    def test_parses_astats_frames(self):
        text = ("frame:0    pts:0       pts_time:0\n"
                "lavfi.astats.Overall.RMS_level=-inf\n"
                "frame:1    pts:1024    pts_time:0.021333\n"
                "lavfi.astats.Overall.RMS_level=-31.5\n")
        self.assertEqual(callrec.parse_astats(text), ([0.0, 0.021333], [-120.0, -31.5]))

    def _track(self):
        # One frame per 0.1 s: a -70 dB floor with -45 dB speech from 5 s to 6 s
        # and a faint -60 dB blip from 8 s to 9 s.
        times = [i / 10 for i in range(100)]
        levels = [-45.0 if 5 <= t <= 6 else -60.0 if 8 <= t <= 9 else -70.0 for t in times]
        return times, levels

    def test_keeps_speech_well_above_the_floor(self):
        self.assertTrue(callrec.speech_gate(*self._track())(5, 6))

    def test_drops_a_faint_blip_at_the_two_track_margin(self):
        self.assertFalse(callrec.speech_gate(*self._track())(8, 9))

    def test_keeps_the_blip_at_the_mixed_margin(self):
        self.assertTrue(callrec.speech_gate(*self._track(), margin_db=callrec.MIXED_MARGIN_DB)(8, 9))

    def test_drops_a_span_with_no_frames(self):
        self.assertFalse(callrec.speech_gate(*self._track())(50, 51))

    def test_passes_everything_when_loudness_is_unknown(self):
        self.assertTrue(callrec.speech_gate([], [])(0, 1))


class Segments(unittest.TestCase):
    def test_uses_word_times_and_drops_silence_and_hallucinations(self):
        segs = [
            {"text": " Hello there.", "start": 0.0, "end": 3.0, "words": [{"start": 1.2, "end": 2.0}]},
            {"text": "  ", "start": 3.0, "end": 4.0},
            {"text": "Thanks for watching.", "start": 4.0, "end": 5.0, "no_speech_prob": 0.9},
            {"text": "Invented.", "start": 6.0, "end": 7.0},
        ]
        kept, dropped = callrec.kept_segments(segs, lambda a, b: a < 6)
        self.assertEqual(kept, [(1.2, "Hello there.")])
        self.assertEqual(dropped, 3)

    def test_merges_consecutive_lines_by_speaker(self):
        turns = callrec.merge_turns([(5.0, "Me", "Sure."), (0.0, "Them", "Hi."), (1.0, "Them", "Ready?"),
                                     (9.0, "Them", "Great.")])
        self.assertEqual(turns, [(0.0, "Them", "Hi. Ready?"), (5.0, "Me", "Sure."), (9.0, "Them", "Great.")])

    def test_stamps(self):
        self.assertEqual(callrec.stamp(65.9), "01:05")
        self.assertEqual(callrec.stamp(3725), "1:02:05")


if __name__ == "__main__":
    unittest.main()

# Shadows any installed mlx_whisper so callrec.py sees the ImportError a machine without
# mlx-whisper would see. Imported only by test/call-recorder.test.mjs.
raise ImportError("mlx-whisper is not installed (test fixture)")

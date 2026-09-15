# Shadows the real `google` namespace package so gsc.py sees the ImportError a machine
# without google-auth would see. Imported only by test/search-console.test.mjs.
raise ImportError("google-auth is not installed (test fixture)")

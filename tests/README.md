# Tests

Sandbox tests for the AUDIT fixes; they touch neither the real Steam config nor the installed plugin. Run them from anywhere with `python3 tests/test_m25_removal_cycles.py` (scanner removal counters, M25) and `bash tests/test_k12_installer.sh` (plugin installer staging/swap, K12); both print `ALL CHECKS PASSED` and exit 0 on success.

"""Multi-cycle test for AUDIT M25: removal counter logic in NSLGameScanner.py.

Extracts scan_and_track_games() via ast (importing the module would run the
whole scanner) and drives it against a temp HOME. Each "cycle" is a fresh
call to scan_and_track_games, matching how the real scanner runs.

Covered:
  1. Game missing 1x/2x -> NOT removed (counter 1, 2); missing 3x -> removed.
  2. Game reappearing after misses -> counter resets to 0 (dropped from file).
  3. Launcher yields no scan data at all -> no counter increment, no removal,
     existing counters carried over unchanged.
  4. Corrupt counter file (invalid JSON / wrong type) -> reset to 0, no removal.
  5. Already-removed games (still_installed=False) are not re-reported.
"""

import ast
import json
import os
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

SCANNER = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "NSLGameScanner.py",
)
STEAMID3 = "12345"

failures = []


def check(name, cond, detail=""):
    status = "PASS" if cond else "FAIL"
    print(f"[{status}] {name}" + (f"  ({detail})" if detail and not cond else ""))
    if not cond:
        failures.append(name)


def load_scan_fn():
    with open(SCANNER) as f:
        src = f.read()
    tree = ast.parse(src)
    fn = next(
        n for n in tree.body
        if isinstance(n, ast.FunctionDef) and n.name == "scan_and_track_games"
    )
    module = ast.Module(body=[fn], type_ignores=[])
    code = compile(module, SCANNER, "exec")
    ns = {
        "os": os, "json": json, "tempfile": tempfile,
        "subprocess": subprocess, "datetime": datetime, "timezone": timezone,
        "vdf": None,  # only touched if shortcuts.vdf exists; it never does here
        "print": print,
    }
    exec(code, ns)
    return ns["scan_and_track_games"]


scan_and_track_games = load_scan_fn()


def run_cycle(home, present):
    """One scanner cycle: launchers/games in `present` are seen; returns removed_apps."""
    track, finalize = scan_and_track_games(home, STEAMID3)
    for launcher, games in present.items():
        for game in games:
            track(game, launcher)
    return finalize()


def counters_file(home):
    return f"{home}/.config/systemd/user/nsl_removal_counters.json"


def master_file(home):
    return f"{home}/.config/systemd/user/installedapps.json"


def read_json(path):
    if not os.path.exists(path):
        return None
    with open(path) as f:
        return json.load(f)


home = tempfile.mkdtemp(prefix="nsl-m25-test-")
try:
    # --- Cycle 0: baseline. itch.io has A+B+C, GOG Galaxy has D+E. ---
    removed = run_cycle(home, {"itch.io": ["A", "B", "C"], "GOG Galaxy": ["D", "E"]})
    check("cycle0: nothing removed on first scan", removed == {}, f"got {removed}")
    check("cycle0: counter file empty", read_json(counters_file(home)) == {})
    master = read_json(master_file(home))
    check("cycle0: master list has all 5 games",
          set(master["itch.io"]) == {"A", "B", "C"} and set(master["GOG Galaxy"]) == {"D", "E"})

    # --- Test 1: B missing 1x/2x -> not removed; 3x -> removed. ---
    removed = run_cycle(home, {"itch.io": ["A", "C"], "GOG Galaxy": ["D", "E"]})
    check("miss 1/3: B not removed", removed == {}, f"got {removed}")
    check("miss 1/3: counter B == 1",
          read_json(counters_file(home)).get("itch.io", {}).get("B") == 1,
          f"counters={read_json(counters_file(home))}")
    check("miss 1/3: B still_installed stays True",
          read_json(master_file(home))["itch.io"]["B"]["still_installed"] is True)

    removed = run_cycle(home, {"itch.io": ["A", "C"], "GOG Galaxy": ["D", "E"]})
    check("miss 2/3: B not removed", removed == {}, f"got {removed}")
    check("miss 2/3: counter B == 2",
          read_json(counters_file(home)).get("itch.io", {}).get("B") == 2)

    removed = run_cycle(home, {"itch.io": ["A", "C"], "GOG Galaxy": ["D", "E"]})
    check("miss 3/3: B removed", removed == {"itch.io": ["B"]}, f"got {removed}")
    check("miss 3/3: B marked still_installed=False",
          read_json(master_file(home))["itch.io"]["B"]["still_installed"] is False)
    check("miss 3/3: counter for B cleared",
          "B" not in read_json(counters_file(home)).get("itch.io", {}),
          f"counters={read_json(counters_file(home))}")

    # --- Test 5: already-removed B must not be reported again. ---
    removed = run_cycle(home, {"itch.io": ["A", "C"], "GOG Galaxy": ["D", "E"]})
    check("post-removal: B not re-reported", removed == {}, f"got {removed}")
    check("post-removal: no counter re-created for B",
          "B" not in read_json(counters_file(home)).get("itch.io", {}))

    # --- Test 2: C missing once, then reappears -> counter reset. ---
    removed = run_cycle(home, {"itch.io": ["A"], "GOG Galaxy": ["D", "E"]})
    check("reappear setup: C counter == 1",
          read_json(counters_file(home)).get("itch.io", {}).get("C") == 1)
    removed = run_cycle(home, {"itch.io": ["A", "C"], "GOG Galaxy": ["D", "E"]})
    check("reappear: C not removed", removed == {}, f"got {removed}")
    check("reappear: C counter dropped (reset to 0)",
          "C" not in read_json(counters_file(home)).get("itch.io", {}),
          f"counters={read_json(counters_file(home))}")
    check("reappear: C still_installed True",
          read_json(master_file(home))["itch.io"]["C"]["still_installed"] is True)

    # --- Test 3: launcher yields no scan data -> counters carried, not counted. ---
    # First give D a real miss (GOG scanned, D absent, E present): counter D=1.
    removed = run_cycle(home, {"itch.io": ["A", "C"], "GOG Galaxy": ["E"]})
    check("no-data setup: D counter == 1",
          read_json(counters_file(home)).get("GOG Galaxy", {}).get("D") == 1)
    # Now GOG delivers nothing at all (SD card missing / DB locked / section failed).
    removed = run_cycle(home, {"itch.io": ["A", "C"]})
    check("no-data cycle: nothing removed", removed == {}, f"got {removed}")
    check("no-data cycle: D counter unchanged at 1 (not incremented)",
          read_json(counters_file(home)).get("GOG Galaxy", {}).get("D") == 1,
          f"counters={read_json(counters_file(home))}")
    check("no-data cycle: E not touched",
          read_json(master_file(home))["GOG Galaxy"]["E"]["still_installed"] is True)
    # GOG back, D still gone: counting resumes at 2, then 3 -> removed.
    removed = run_cycle(home, {"itch.io": ["A", "C"], "GOG Galaxy": ["E"]})
    check("resume: D counter == 2",
          read_json(counters_file(home)).get("GOG Galaxy", {}).get("D") == 2)
    removed = run_cycle(home, {"itch.io": ["A", "C"], "GOG Galaxy": ["E"]})
    check("resume: D removed on 3rd countable miss", removed == {"GOG Galaxy": ["D"]},
          f"got {removed}")

    # --- Test 4a: corrupt counter file (invalid JSON) -> reset, no removal. ---
    # Build a game with counter 2, one miss away from removal.
    removed = run_cycle(home, {"itch.io": ["C"], "GOG Galaxy": ["E"]})  # A miss 1
    removed = run_cycle(home, {"itch.io": ["C"], "GOG Galaxy": ["E"]})  # A miss 2
    check("corrupt setup: A counter == 2",
          read_json(counters_file(home)).get("itch.io", {}).get("A") == 2)
    with open(counters_file(home), "w") as f:
        f.write("{ this is not json")
    removed = run_cycle(home, {"itch.io": ["C"], "GOG Galaxy": ["E"]})  # A would hit 3
    check("corrupt file: A NOT removed (reset instead)", removed == {}, f"got {removed}")
    check("corrupt file: A counter restarted at 1",
          read_json(counters_file(home)).get("itch.io", {}).get("A") == 1,
          f"counters={read_json(counters_file(home))}")

    # --- Test 4b: wrong JSON type (array) -> same reset behavior. ---
    removed = run_cycle(home, {"itch.io": ["C"], "GOG Galaxy": ["E"]})  # A back to 2
    check("wrongtype setup: A counter == 2",
          read_json(counters_file(home)).get("itch.io", {}).get("A") == 2)
    with open(counters_file(home), "w") as f:
        json.dump(["not", "a", "dict"], f)
    removed = run_cycle(home, {"itch.io": ["C"], "GOG Galaxy": ["E"]})
    check("wrongtype file: A NOT removed", removed == {}, f"got {removed}")
    check("wrongtype file: A counter restarted at 1",
          read_json(counters_file(home)).get("itch.io", {}).get("A") == 1)

    # --- Test 4c: missing counter file -> counts from 0, no removal. ---
    os.remove(counters_file(home))
    removed = run_cycle(home, {"itch.io": ["C"], "GOG Galaxy": ["E"]})
    check("missing file: A NOT removed", removed == {}, f"got {removed}")
    check("missing file: A counter restarted at 1",
          read_json(counters_file(home)).get("itch.io", {}).get("A") == 1)

finally:
    shutil.rmtree(home, ignore_errors=True)

print()
if failures:
    print(f"{len(failures)} FAILURE(S): {failures}")
    sys.exit(1)
print("ALL CHECKS PASSED")

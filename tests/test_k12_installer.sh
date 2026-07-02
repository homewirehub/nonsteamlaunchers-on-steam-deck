#!/bin/bash
# Behavioral test for the K12 rework of NSLPluginInstaller.sh.
# Runs a copy of the real script in a sandbox HOME with stubbed
# zenity/sudo/qdbus/systemctl. The ONLY divergence from the real script is
# the logged_in_home line, which is pointed at the sandbox.

set -u
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REAL_SCRIPT="${SCRIPT_DIR}/../NSLPluginInstaller.sh"
SANDBOX=$(mktemp -d /tmp/nsl-k12-sandbox.XXXXXX)
FAILURES=0

cleanup() {
  if [ "$FAILURES" -eq 0 ]; then
    rm -rf "$SANDBOX"
  else
    echo "Sandbox kept for inspection: $SANDBOX"
  fi
}
trap cleanup EXIT

check() { # name, condition-result
  if [ "$2" -eq 0 ]; then echo "[PASS] $1"; else echo "[FAIL] $1"; FAILURES=$((FAILURES+1)); fi
}

mkdir -p "$SANDBOX/home" "$SANDBOX/bin"

# --- Test copy of the script: only redirect logged_in_home ---
sed 's|^logged_in_home=.*|logged_in_home="'"$SANDBOX/home"'"|' "$REAL_SCRIPT" > "$SANDBOX/installer.sh"
if ! diff <(grep -v '^logged_in_home=' "$REAL_SCRIPT") <(grep -v '^logged_in_home=' "$SANDBOX/installer.sh") >/dev/null; then
  echo "[FAIL] test copy diverges from real script beyond logged_in_home"; FAILURES=1; exit 1
fi

# --- Stubs ---
cat > "$SANDBOX/bin/zenity" <<'EOF'
#!/bin/bash
echo "zenity $*" >> "$ZENITY_LOG"
for arg in "$@"; do
  case "$arg" in
    --password) echo "stubpw"; exit 0 ;;
  esac
done
if [[ " $* " == *" --question "* ]]; then
  # Yes to "install or update?", No to "switch to Game Mode?"
  [[ "$*" == *"install or update"* ]] && exit 0 || exit 1
fi
exit 0
EOF
cat > "$SANDBOX/bin/sudo" <<'EOF'
#!/bin/bash
# Stub: swallow -S (and its stdin) and -v, run the rest as the test user.
[[ "$1" == "-S" ]] && { shift; cat >/dev/null; }
[[ "${1:-}" == "-v" ]] && exit 0
exec "$@"
EOF
cat > "$SANDBOX/bin/qdbus" <<'EOF'
#!/bin/bash
exit 0
EOF
cp "$SANDBOX/bin/qdbus" "$SANDBOX/bin/systemctl"
chmod +x "$SANDBOX/bin/"*

run_installer() {
  ZENITY_LOG="$SANDBOX/zenity.log" PATH="$SANDBOX/bin:$PATH" bash "$SANDBOX/installer.sh" \
    > "$SANDBOX/run.log" 2>&1
  echo $?
}

HOME_DIR="$SANDBOX/home"
SRC="$HOME_DIR/NonSteamLaunchersDecky"
PLUGIN="$HOME_DIR/homebrew/plugins/NonSteamLaunchers"

make_checkout() {
  rm -rf "$SRC"
  mkdir -p "$SRC/dist" "$SRC/py_modules" "$SRC/.git"
  echo '{"name": "nsl", "version": "1.2.3"}' > "$SRC/package.json"
  echo '{"name": "NonSteamLaunchers"}' > "$SRC/plugin.json"
  echo 'print("plugin v1")' > "$SRC/main.py"
  echo 'console.log(1)' > "$SRC/dist/index.js"
  echo 'gitdata' > "$SRC/.git/HEAD"
}

mkdir -p "$HOME_DIR/homebrew/plugins"

# =========================================================================
echo "--- (a) checkout missing -> clear error, exit 1, nothing installed ---"
: > "$SANDBOX/zenity.log"
rc=$(run_installer)
check "a: exit code 1" "$([ "$rc" -eq 1 ]; echo $?)"
grep -q "ERROR: Decky plugin checkout not found at ${SRC}" "$SANDBOX/run.log"
check "a: clear ERROR line on stdout" $?
grep -q -- "--error" "$SANDBOX/zenity.log" && grep -q "checkout not found" "$SANDBOX/zenity.log"
check "a: zenity --error shown" $?
[ ! -d "$PLUGIN" ]
check "a: no plugin dir created" $?
grep -q -- "--password" "$SANDBOX/zenity.log"
check "a: fails BEFORE sudo password prompt" "$([ $? -ne 0 ]; echo $?)"

# =========================================================================
echo "--- (b) valid checkout, fresh install ---"
make_checkout
: > "$SANDBOX/zenity.log"
rc=$(run_installer)
check "b: exit code 0" "$([ "$rc" -eq 0 ]; echo $?)"
[ -f "$PLUGIN/main.py" ] && [ -f "$PLUGIN/dist/index.js" ] && [ -f "$PLUGIN/plugin.json" ]
check "b: plugin files installed" $?
[ ! -d "$PLUGIN/.git" ]
check "b: .git not copied into plugin" $?
grep -q "Updating from none to 1.2.3" "$SANDBOX/zenity.log"
check "b: update message 'none -> 1.2.3'" $?
ls -d "$PLUGIN".new.* "$PLUGIN".old.* 2>/dev/null
check "b: no .new/.old leftovers" "$([ $? -ne 0 ]; echo $?)"
ls /tmp/NSLDeckyStaging.* 2>/dev/null
check "b: staging dir cleaned up (trap)" "$([ $? -ne 0 ]; echo $?)"

# =========================================================================
echo "--- (c) rerun unchanged -> up-to-date, no reinstall ---"
: > "$SANDBOX/zenity.log"
inode_before=$(stat -c %i "$PLUGIN/main.py")
rc=$(run_installer)
check "c: exit code 0" "$([ "$rc" -eq 0 ]; echo $?)"
grep -q "No update needed" "$SANDBOX/zenity.log"
check "c: 'No update needed' message" $?
inode_after=$(stat -c %i "$PLUGIN/main.py")
[ "$inode_before" = "$inode_after" ]
check "c: installed files untouched (same inode)" $?

# =========================================================================
echo "--- (d) source edited -> reinstall picks up change ---"
echo 'print("plugin v2")' > "$SRC/main.py"
: > "$SANDBOX/zenity.log"
rc=$(run_installer)
check "d: exit code 0" "$([ "$rc" -eq 0 ]; echo $?)"
grep -q 'plugin v2' "$PLUGIN/main.py"
check "d: edited main.py deployed" $?
grep -q "Updating from 1.2.3 to 1.2.3" "$SANDBOX/zenity.log"
check "d: update ran despite equal versions (content diff)" $?
ls -d "$PLUGIN".new.* "$PLUGIN".old.* 2>/dev/null
check "d: no .new/.old leftovers" "$([ $? -ne 0 ]; echo $?)"

# =========================================================================
echo "--- (e) incomplete checkout -> error, installed plugin untouched ---"
rm "$SRC/plugin.json"
echo 'print("plugin v3 - must not deploy")' > "$SRC/main.py"
: > "$SANDBOX/zenity.log"
rc=$(run_installer)
check "e: exit code 1" "$([ "$rc" -eq 1 ]; echo $?)"
grep -q "ERROR: ${SRC}/plugin.json missing" "$SANDBOX/run.log"
check "e: clear ERROR line names missing file" $?
grep -q 'plugin v2' "$PLUGIN/main.py"
check "e: installed plugin untouched (still v2)" $?

# =========================================================================
echo "--- (f) empty/broken package.json in source -> still no data loss ---"
make_checkout
echo 'print("plugin v4")' > "$SRC/main.py"
echo 'garbage, no version field' > "$SRC/package.json"
: > "$SANDBOX/zenity.log"
rc=$(run_installer)
check "f: exit code 0 (version is display-only now)" "$([ "$rc" -eq 0 ]; echo $?)"
grep -q 'plugin v4' "$PLUGIN/main.py"
check "f: update deployed" $?
grep -q "Updating from 1.2.3 to unknown" "$SANDBOX/zenity.log"
check "f: empty source version shown as 'unknown'" $?

echo
if [ "$FAILURES" -gt 0 ]; then echo "$FAILURES FAILURE(S)"; exit 1; fi
echo "ALL CHECKS PASSED"

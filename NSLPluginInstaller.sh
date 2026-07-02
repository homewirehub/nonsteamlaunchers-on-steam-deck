#!/bin/bash

# TODO (AUDIT K12 leftover): no lockfile against parallel starts - two
# concurrent installer runs could interleave while swapping the plugin.
# The $$-suffixed staging directories defuse most of it; the proper fix
# is a flock around the update block.

# ENVIRONMENT VARIABLES
logged_in_user=$(logname 2>/dev/null || whoami)
logged_in_home=$(eval echo "~${logged_in_user}")

# Function to prompt for sudo password
prompt_for_sudo() {
  password=$(zenity --password --title="Authentication Required" --text="Please enter your password to proceed with installation/update.")

  # Validate password
  echo "$password" | sudo -S -v >/dev/null 2>&1
  if [ $? -ne 0 ]; then
    zenity --error --text="Incorrect password or sudo failed. Exiting."
    exit 1
  fi
}

# Function to switch to Game Mode
switch_to_game_mode() {
  echo "Switching to Game Mode..."
  rm -rf "${logged_in_home}/.config/systemd/user/nslgamescanner.service"
  unlink "${logged_in_home}/.config/systemd/user/default.target.wants/nslgamescanner.service"
  systemctl --user daemon-reload
  qdbus org.kde.Shutdown /Shutdown org.kde.Shutdown.logout
}

# Function to display Zenity messages
show_message() {
  zenity --notification --text="$1" --timeout=1
}

show_update_message() {
  zenity --notification --text="Updating from $1 to $2..." --timeout=5
}

# Set paths
# Dev fork (AUDIT K12): the plugin is installed from this local checkout
# instead of being downloaded from moraroy/main on every update.
DECKY_SRC="${logged_in_home}/NonSteamLaunchersDecky"
LOCAL_DIR="${logged_in_home}/homebrew/plugins/NonSteamLaunchers"

# Ask the user
zenity --question --text="Would you like to install or update the NonSteamLaunchers Decky Plugin?" --title="Install/Update Plugin" --ok-label="Yes" --cancel-label="No"
if [ $? -eq 1 ]; then
  echo "User canceled the installation/update."
  exit 0
fi

# AUDIT K12: a missing or incomplete plugin source must abort loudly before
# anything else happens - it must never lead to the installed plugin being
# removed (guard style as in update_nsl_game_scanner).
required_plugin_files=("plugin.json" "package.json" "main.py" "dist/index.js")

if [ ! -d "$DECKY_SRC" ]; then
  echo "ERROR: Decky plugin checkout not found at ${DECKY_SRC} - clone NonSteamLaunchersDecky there first."
  zenity --error --text="Decky plugin checkout not found at:\n${DECKY_SRC}\n\nClone the NonSteamLaunchersDecky repo there first. The installed plugin was left untouched."
  exit 1
fi

for f in "${required_plugin_files[@]}"; do
  if [ ! -f "${DECKY_SRC}/${f}" ]; then
    echo "ERROR: ${DECKY_SRC}/${f} missing - checkout incomplete, not touching the installed plugin."
    zenity --error --text="Plugin source at ${DECKY_SRC} is incomplete (missing ${f}).\n\nThe installed plugin was left untouched."
    exit 1
  fi
done

# Prompt for sudo once
prompt_for_sudo

# Check for existing directories
DECKY_LOADER_EXISTS=false
NSL_PLUGIN_EXISTS=false

if [ -d "${logged_in_home}/homebrew/plugins" ]; then
  DECKY_LOADER_EXISTS=true
fi

if [ -d "$LOCAL_DIR" ] && [ -n "$(ls -A "$LOCAL_DIR")" ]; then
  NSL_PLUGIN_EXISTS=true
fi

# Version extraction from JSON (no jq)
extract_version() {
  grep -o '"version": *"[^"]*"' "$1" | sed 's/.*"version": *"\([^"]*\)".*/\1/'
}

fetch_source_version() {
  extract_version "$DECKY_SRC/package.json"
}

fetch_local_version() {
  if [ -f "$LOCAL_DIR/package.json" ]; then
    version=$(extract_version "$LOCAL_DIR/package.json")
    echo "$version"
  fi
}

# Main logic
set +x

# Sanity checks
if $DECKY_LOADER_EXISTS; then
  if ! $NSL_PLUGIN_EXISTS; then
    zenity --info --text="Decky Loader is detected but no NSL plugin found. It will now be injected into Game Mode."
  fi
else
  zenity --error --text="Decky Loader not found. Please install it and re-run the script."
  exit 1
fi

# AUDIT K12: stage and verify the new plugin fully before the installed one
# is touched; the old install is only moved aside once the verified copy sits
# next to it, and is restored if the final swap fails.
staging_dir=$(mktemp -d /tmp/NSLDeckyStaging.XXXXXX)
trap 'rm -rf "$staging_dir"' EXIT

if ! cp -r "$DECKY_SRC"/* "$staging_dir"/; then
  echo "ERROR: copying the plugin source to staging failed."
  zenity --error --text="Copying the plugin source failed.\n\nThe installed plugin was left untouched."
  exit 1
fi
rm -rf "$staging_dir/node_modules"

for f in "${required_plugin_files[@]}"; do
  if [ ! -f "${staging_dir}/${f}" ]; then
    echo "ERROR: staged plugin copy incomplete (${f} missing), not touching the installed plugin."
    zenity --error --text="Staged plugin copy is incomplete (missing ${f}).\n\nThe installed plugin was left untouched."
    exit 1
  fi
done

if [ -d "$LOCAL_DIR" ] && diff -rq "$staging_dir" "$LOCAL_DIR" >/dev/null 2>&1; then
  show_message "No update needed. The plugin is already up-to-date."
else
  local_version=$(fetch_local_version)
  source_version=$(fetch_source_version)
  show_update_message "${local_version:-none}" "${source_version:-unknown}"

  new_dir="${LOCAL_DIR}.new.$$"
  old_dir="${LOCAL_DIR}.old.$$"
  echo "$password" | sudo -S rm -rf "$new_dir" "$old_dir"

  if ! echo "$password" | sudo -S cp -r "$staging_dir" "$new_dir"; then
    echo "$password" | sudo -S rm -rf "$new_dir"
    echo "ERROR: preparing the new plugin copy failed."
    zenity --error --text="Preparing the new plugin copy failed.\n\nThe installed plugin was left untouched."
    exit 1
  fi
  echo "$password" | sudo -S chmod -R u+rw "$new_dir"
  echo "$password" | sudo -S chown -R "$logged_in_user:$logged_in_user" "$new_dir"

  if [ -d "$LOCAL_DIR" ]; then
    if ! echo "$password" | sudo -S mv "$LOCAL_DIR" "$old_dir"; then
      echo "$password" | sudo -S rm -rf "$new_dir"
      echo "ERROR: could not move the old plugin aside; nothing was changed."
      zenity --error --text="Could not move the old plugin aside.\n\nNothing was changed."
      exit 1
    fi
  fi

  if ! echo "$password" | sudo -S mv "$new_dir" "$LOCAL_DIR"; then
    if [ -d "$old_dir" ]; then
      echo "$password" | sudo -S mv "$old_dir" "$LOCAL_DIR"
    fi
    echo "ERROR: installing the new plugin failed; the previous version was restored."
    zenity --error --text="Installing the new plugin failed.\n\nThe previous version was restored."
    exit 1
  fi

  echo "$password" | sudo -S rm -rf "$old_dir"
fi

set -x
cd "$LOCAL_DIR"






# Ask to switch to Game Mode
zenity --question --text="Plugin installed or updated. Do you want to switch to Game Mode now?" --title="Switch to Game Mode?" --ok-label="Yes" --cancel-label="No"
if [ $? -eq 0 ]; then
  switch_to_game_mode
else
  show_message "Remaining in Desktop Mode."
fi

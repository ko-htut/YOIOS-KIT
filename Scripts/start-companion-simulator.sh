#!/bin/zsh
set -euo pipefail
umask 077

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
if (( $# != 1 )); then
  print -u2 -- "Usage: Scripts/start-companion-simulator.sh EXACT_BOOTED_IPHONE_SIMULATOR_UUID"
  print -u2 -- "Build the simulator app with Scripts/build-companion.sh --simulator first."
  exit 64
fi
exec /usr/bin/python3 "${project_dir}/Backend/CompanionSimulator/launch_companion.py" "$1"

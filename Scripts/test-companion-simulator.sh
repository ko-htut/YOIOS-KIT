#!/bin/zsh
set -euo pipefail
umask 077
script_dir="${0:A:h}"
exec /usr/bin/python3 "${script_dir:h}/Backend/CompanionSimulator/run_ui_tests.py" "$@"

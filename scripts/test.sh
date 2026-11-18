#!/bin/bash
# Everyday headless checks; fixture startup is opt-in via check-all.sh.
set -euo pipefail
if [[ $# != 0 ]]; then echo "usage: ${0##*/}" >&2; exit 2; fi
exec "$(dirname -- "$0")/check-all.sh"

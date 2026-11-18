#!/bin/bash
set -euo pipefail
exec /bin/bash "$(dirname -- "$0")/lib/run-checks.sh" navigation "$@"

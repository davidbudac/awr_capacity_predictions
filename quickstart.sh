#!/usr/bin/env bash
# quickstart.sh -- preflight + install + first report, in one command.
#
#   ./quickstart.sh                       # sqlplus / as sysdba   (CDB$ROOT)
#   ./quickstart.sh user/pw@//host/svc    # any connect string sqlplus accepts
#
# Needs sqlplus on PATH (source oraenv first on the DB host). Runs from the
# repo directory regardless of where you call it from, because the SQL*Plus
# @@ includes resolve relative to the outermost script.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

command -v sqlplus >/dev/null 2>&1 || {
  echo "quickstart: sqlplus not found on PATH (on the DB host: . oraenv)" >&2
  exit 1
}
mkdir -p reports

if [ "$#" -eq 0 ]; then
  exec sqlplus -L / as sysdba @quickstart.sql </dev/null
else
  exec sqlplus -L "$@" @quickstart.sql </dev/null
fi

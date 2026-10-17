#!/bin/sh
# Lab wrapper: regenerate the AWR Capacity APEX app and install it into the
# local Oracle Free container as SYSTEM.  Writes only APEX metadata in that
# container's PDB; never touches the suite's tables.
# Env overrides: APEX_CONTAINER (23cfree), APEX_PDB (FREEPDB1),
# APEX_WORKSPACE (AWRCAP), APEX_SCHEMA (AWRCAP), APEX_APP_ID (110).
set -eu
cd "$(dirname "$0")/.."
container=${APEX_CONTAINER:-23cfree}
pdb=${APEX_PDB:-FREEPDB1}
workspace=${APEX_WORKSPACE:-AWRCAP}
schema=${APEX_SCHEMA:-AWRCAP}
app_id=${APEX_APP_ID:-110}
python3 apex/build.py --smoke
docker exec "$container" mkdir -p /tmp/awrcap/apex/test
docker cp apex/awrcap_app.sql "$container:/tmp/awrcap/apex/"
docker cp apex/install.sql "$container:/tmp/awrcap/apex/"
docker cp apex/workspace.sql "$container:/tmp/awrcap/apex/"
docker cp apex/test/apex_smoke.sql "$container:/tmp/awrcap/apex/test/"
# The container supplies ORACLE_PWD; it is expanded inside the container only.
docker exec -i -u oracle "$container" bash -lc '
  set -eu
  cd /tmp/awrcap/apex
  sqlplus -s -L "system/${ORACLE_PWD}@localhost:1521/$1" @install.sql "$2" "$3" "$4"
' sh "$pdb" "$workspace" "$schema" "$app_id" <<'SQL'
exit
SQL
echo "Published application $app_id. Smoke test (as $schema): cd /tmp/awrcap/apex && sqlplus $schema@$pdb @test/apex_smoke.sql $app_id"

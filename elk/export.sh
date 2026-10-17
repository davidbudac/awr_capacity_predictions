#!/usr/bin/env bash
# elk/export.sh -- run on the DB host as the Oracle owner: export the capacity
# suite's analytics as NDJSON for Filebeat (which ships it to Logstash, which
# indexes it as awrcap-capacity). No Elasticsearch access from here.
#
#   elk/export.sh --sid cdb1 --container PDB1 --schema CAPDEMO
#   elk/export.sh --sid cdb1                     # local-mode install in CDB$ROOT
#
# Options: --sid SID  --container PDB  --schema OWNER
#          --source LABEL   (default sid[/container][:schema]; keys the documents)
#          --out DIR        (default /u01/app/oracle/filebeat/generated, the
#                            directory elk/filebeat/awrcap.yml tails)
#          --retention-days N  (delete awrcap-*.ndjson older than N days, default 7)
#          --stdout         (print the validated NDJSON instead of writing a file)
# Every run appends one file per source and day; documents carry deterministic
# ids, so Elasticsearch overwrites instead of duplicating. Needs bash, python3,
# sqlplus on PATH after the oraenv preamble (ORACLE_SID is enough).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
sid="" container="" schema="" source_label="" to_stdout=""
out_dir=/u01/app/oracle/filebeat/generated
retention_days=7

die() { echo "export.sh: $*" >&2; exit 1; }
while (($#)); do
    case $1 in
        --stdout) to_stdout=1; shift; continue ;;
    esac
    [[ $# -ge 2 ]] || die "missing value for $1"
    case $1 in
        --sid)            sid=$2 ;;
        --container)      container=$2 ;;
        --schema)         schema=$2 ;;
        --source)         source_label=$2 ;;
        --out)            out_dir=$2 ;;
        --retention-days) retention_days=$2 ;;
        *) die "unknown option $1" ;;
    esac
    shift 2
done
if [[ -z $source_label ]]; then
    source_label=${sid:-local}${container:+/$container}${schema:+:$schema}
fi
[[ $source_label != *\"* ]] || die "--source must not contain a double quote"
[[ $retention_days =~ ^[0-9]+$ ]] || die "--retention-days must be an integer"

oracle_env=""
if [[ -n $sid ]]; then
    oracle_env="export ORACLE_SID=$sid; export ORAENV_ASK=NO; . oraenv >/dev/null 2>&1; "
fi

sql_script() {
    echo "SET FEEDBACK OFF"
    echo "WHENEVER SQLERROR EXIT FAILURE"
    echo "WHENEVER OSERROR EXIT FAILURE"
    [[ -n $container ]] && echo "ALTER SESSION SET CONTAINER = $container;"
    [[ -n $schema ]] && echo "ALTER SESSION SET CURRENT_SCHEMA = $schema;"
    echo "DEFINE cap_source = \"$source_label\""
    cat "$here/export_capacity.sql"
    echo
    echo "EXIT"
}

raw=$(mktemp -t awrcap.XXXXXX)
trap 'rm -f "$raw"' EXIT
sql_script | bash -c "${oracle_env}sqlplus -S -L / as sysdba" > "$raw" \
    || { cat "$raw" >&2; die "export failed"; }

# Validate every line against the mapping before Filebeat ever sees it: a
# document with an unmapped field is rejected by Elasticsearch far downstream,
# where only the Logstash log would show it.
TEMPLATE="$here/elasticsearch/index-template.json" python3 - "$raw" <<'PY'
import collections, json, os, sys

path = sys.argv[1]
mappings = json.load(open(os.environ["TEMPLATE"]))["template"]["mappings"]


def fail(msg):
    sys.exit(f"export.sh: {msg}")


def leaf_paths(props, prefix=""):
    for name, spec in props.items():
        if "properties" in spec:
            yield from leaf_paths(spec["properties"], f"{prefix}{name}.")
        else:
            yield prefix + name


def doc_paths(obj, prefix=""):
    for k, v in obj.items():
        if isinstance(v, dict):
            yield from doc_paths(v, f"{prefix}{k}.")
        else:
            yield prefix + k


allowed = set(leaf_paths(mappings["properties"])) | {"id"}
ids = collections.Counter()
counts = collections.Counter()
with open(path) as fh:
    for n, line in enumerate(fh, 1):
        line = line.strip()
        if not line:
            continue
        if not line.startswith("{"):
            fail(f"line {n} is not a JSON document (SQL*Plus error?): {line}")
        try:
            doc = json.loads(line)
        except json.JSONDecodeError as e:
            fail(f"line {n} is not valid JSON ({e}): {line[:300]}")
        if not doc.get("id") or "@timestamp" not in doc or "record" not in doc.get("cap", {}):
            fail(f"line {n} lacks id/@timestamp/cap.record: {line[:300]}")
        unknown = set(doc_paths(doc)) - allowed
        if unknown:
            fail(f"line {n} has fields not in the index template {sorted(unknown)}: {line[:300]}")
        ids[doc["id"]] += 1
        counts[(doc["cap"]["record"], doc["cap"]["kind"])] += 1
if not ids:
    fail("the export produced no documents")
dupes = [i for i, c in ids.items() if c > 1]
if dupes:
    fail(f"{len(dupes)} duplicate ids, e.g. {dupes[0]}")
for (rec, kind), c in sorted(counts.items()):
    print(f"{rec:12} {kind:7} {c:6}", file=sys.stderr)
print(f"{sum(ids.values())} documents validated", file=sys.stderr)
PY

if [[ -n $to_stdout ]]; then
    grep '^{' "$raw"
    exit 0
fi

mkdir -p "$out_dir"
slug=$(printf '%s' "$source_label" | tr -c 'A-Za-z0-9' '_')
out="$out_dir/awrcap-${slug}-$(date -u +%Y%m%d).ndjson"
grep '^{' "$raw" >> "$out"
chmod 600 "$out"
find "$out_dir" -name 'awrcap-*.ndjson' -type f -mtime "+$retention_days" -delete
echo "appended to $out"

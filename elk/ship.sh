#!/usr/bin/env bash
# elk/ship.sh -- export the capacity suite's analytics and load them into
# Elasticsearch (index awrcap-capacity, mapping elk/elasticsearch/index-template.json).
#
#   elk/ship.sh --ssh 'oracle@dbmint -p 2200' --sid cdb1 --container PDB1 --schema CAPDEMO
#   elk/ship.sh --sid cdb1 --schema CAPTEST --dry-run /tmp/cap.ndjson   # local sqlplus, no ES
#
# Options: --ssh 'user@host [ssh opts]'  --sid SID  --container PDB  --schema OWNER
#          --source LABEL (default sid[/container][:schema])  --index NAME
#          --es URL --es-user U --es-password P (else $ES_URL/$ES_USER/$ES_PASSWORD)
#          --dry-run FILE (write the NDJSON and stop)
# Re-running is idempotent: documents carry deterministic _ids; forecasts the
# current run no longer produces are deleted. Needs bash, python3, sqlplus (here or via ssh).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
ssh_target="" sid="" container="" schema="" source_label="" dry_run=""
es_url=${ES_URL:-http://localhost:9200}
es_user=${ES_USER:-elastic}
es_password=${ES_PASSWORD:-changeme}
index=awrcap-capacity

die() { echo "ship.sh: $*" >&2; exit 1; }
while (($#)); do
    [[ $# -ge 2 ]] || die "missing value for $1"
    case $1 in
        --ssh)         ssh_target=$2 ;;
        --sid)         sid=$2 ;;
        --container)   container=$2 ;;
        --schema)      schema=$2 ;;
        --source)      source_label=$2 ;;
        --es)          es_url=$2 ;;
        --es-user)     es_user=$2 ;;
        --es-password) es_password=$2 ;;
        --index)       index=$2 ;;
        --dry-run)     dry_run=$2 ;;
        *) die "unknown option $1" ;;
    esac
    shift 2
done
if [[ -z $source_label ]]; then
    source_label=${sid:-local}${container:+/$container}${schema:+:$schema}
fi
[[ $source_label != *\"* ]] || die "--source must not contain a double quote"

oracle_env=""
if [[ -n $sid ]]; then
    oracle_env="export ORACLE_SID=$sid; export ORAENV_ASK=NO; . oraenv >/dev/null 2>&1; "
fi
sqlplus_cmd="${oracle_env}sqlplus -S -L / as sysdba"

# The SQL travels over stdin, so the DB host needs no copy of the repo.
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

ndjson=${dry_run:-$(mktemp -t awrcap.XXXXXX.ndjson)}
[[ -n $dry_run ]] || trap 'rm -f "$ndjson"' EXIT

if [[ -n $ssh_target ]]; then
    read -ra ssh_args <<< "$ssh_target"
    sql_script | ssh "${ssh_args[@]}" "$sqlplus_cmd" > "$ndjson" || { cat "$ndjson" >&2; die "export failed"; }
else
    sql_script | bash -c "$sqlplus_cmd" > "$ndjson" || { cat "$ndjson" >&2; die "export failed"; }
fi

ES_URL=$es_url ES_USER=$es_user ES_PASSWORD=$es_password INDEX=$index SOURCE=$source_label \
DRY_RUN=${dry_run:+1} TEMPLATE="$here/elasticsearch/index-template.json" \
python3 - "$ndjson" <<'PY'
import base64, collections, json, os, sys, urllib.error, urllib.request

ndjson_path = sys.argv[1]
es, index, source = os.environ["ES_URL"].rstrip("/"), os.environ["INDEX"], os.environ["SOURCE"]
auth = "Basic " + base64.b64encode(f'{os.environ["ES_USER"]}:{os.environ["ES_PASSWORD"]}'.encode()).decode()
template = json.load(open(os.environ["TEMPLATE"]))
mappings = template["template"]["mappings"]


def fail(msg):
    sys.exit(f"ship.sh: {msg}")


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


allowed = set(leaf_paths(mappings["properties"]))
docs = []
with open(ndjson_path) as fh:
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
        doc_id = doc.pop("id", None)
        if not doc_id or "@timestamp" not in doc or "record" not in doc.get("cap", {}):
            fail(f"line {n} lacks id/@timestamp/cap.record: {line[:300]}")
        unknown = set(doc_paths(doc)) - allowed
        if unknown:
            fail(f"line {n} has fields not in the index template {sorted(unknown)}: {line[:300]}")
        docs.append((doc_id, doc))
if not docs:
    fail("the export produced no documents")
ids = collections.Counter(i for i, _ in docs)
dupes = [i for i, c in ids.items() if c > 1]
if dupes:
    fail(f"{len(dupes)} duplicate ids, e.g. {next(d for i, d in docs if i == dupes[0])}")

counts = collections.Counter((d["cap"]["record"], d["cap"]["kind"]) for _, d in docs)
exported_at = docs[0][1]["cap"]["exported_at"]

if os.environ.get("DRY_RUN"):
    for (rec, kind), c in sorted(counts.items()):
        print(f"{rec:12} {kind:7} {c:6}")
    print(f"dry run: {len(docs)} documents validated in {ndjson_path}")
    sys.exit(0)


def es_call(method, path, body=None, ndjson=False, ok404=False):
    data = None
    if body is not None:
        data = body.encode() if isinstance(body, str) else json.dumps(body).encode()
    req = urllib.request.Request(es + path, data=data, method=method, headers={
        "Authorization": auth,
        "Content-Type": "application/x-ndjson" if ndjson else "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        if ok404 and e.code == 404:
            return None
        fail(f"{method} {path} -> HTTP {e.code}: {e.read().decode()[:2000]}")
    except urllib.error.URLError as e:
        fail(f"{method} {path} -> {e.reason}")


es_call("PUT", f"/_index_template/{index}", template)
if es_call("GET", f"/{index}/_mapping", ok404=True) is not None:
    # The template only shapes new indices; push additive mapping changes too.
    es_call("PUT", f"/{index}/_mapping", mappings)

for start in range(0, len(docs), 2000):
    lines = []
    for doc_id, doc in docs[start:start + 2000]:
        lines.append(json.dumps({"index": {"_index": index, "_id": doc_id}}))
        lines.append(json.dumps(doc, separators=(",", ":")))
    res = es_call("POST", "/_bulk", "\n".join(lines) + "\n", ndjson=True)
    if res.get("errors"):
        first = next(i for i in res["items"] if "error" in next(iter(i.values())))
        fail(f"bulk error: {json.dumps(first)}")

stale = es_call("POST", f"/{index}/_delete_by_query?refresh=true&conflicts=proceed", {"query": {"bool": {"filter": [
    {"term": {"cap.record": "forecast"}},
    {"term": {"cap.source": source}},
    {"range": {"cap.exported_at": {"lt": exported_at}}}]}}})
es_call("POST", f"/{index}/_refresh")
total = es_call("GET", f"/{index}/_count")["count"]
mine = es_call("POST", f"/{index}/_count", {"query": {"term": {"cap.source": source}}})["count"]

for (rec, kind), c in sorted(counts.items()):
    print(f"{rec:12} {kind:7} {c:6}")
print(f"shipped {len(docs)} documents from {source} (exported_at {exported_at}); "
      f"deleted {stale['deleted']} stale forecasts")
print(f"{index}: {mine} documents from {source}, {total} in total")
PY

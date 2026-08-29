# `bench/` — swingbench workload harness

Generates realistic, *shaped* database load so this toolkit has genuine AWR
history to forecast from. Everything here is optional: the suite itself never
depends on it, and nothing in `bench/` is installed into the database by
`install.sql`.

## Why it exists

The forecast views need **daily** aggregates — `CAP_CONFIG.min_train_days` is
14 — and the anomaly views need a baseline to deviate from. A test database
with an idle instance and hourly snapshots produces `INSUFFICIENT_HISTORY`
everywhere. This harness fixes that by running a repeatable daily load profile:

- **SOE (Order Entry, PL/SQL V2)** — OLTP inserts grow `SOETBS` monotonically,
  which is what `CAPF_TBSPC_FORECAST` / days-to-full needs.
- **SH (Sales History)** — rollups and cubes burn CPU with essentially no
  growth, so the CPU series and the tablespace series move independently.
- **Weekday/weekend contrast** — weekends run a reduced shape, giving
  `CAP_CONFIG.dow_weeks` (day-of-week CPU baseline) a real seasonal signal.
- **An injectable anomaly** — `anomaly_load.sql` plus a 24-user burst, so
  `CAPA_TBSPC_ANOM` / `CAPA_CPU_ANOM` have a true outlier to detect.

## Layout

| Path | What |
| --- | --- |
| `env.sh.example` | copy to `env.sh` (gitignored) and fill in — the only place credentials live |
| `lib/common.sh` | shared helpers: SQL\*Plus-over-SSH, forced AWR snapshots, logging |
| `setup/01_awr_settings.sql` | 15-minute snapshots, 35-day retention (CDB$ROOT) |
| `setup/02_bench_objects.sql` | `SOETBS` + `SHTBS` (capped autoextend) and a PDB-local wizard DBA |
| `setup/setup.sh` | runs both of the above, then `oewizard` / `shwizard` |
| `configs/soe_oltp.xml`, `configs/sh_dss.xml` | charbench configs — **no host, no password**; overridden per run |
| `run_phase.sh` | one phase (`ramp`/`peak`/`dss`/`mixed`/`batch`/`anomaly`) |
| `run_day.sh` | the whole shape back-to-back, for an ad-hoc session |
| `anomaly_load.sql` | bulk load that produces the tablespace outlier |
| `cron/bench.crontab` | example schedule, one entry per phase |
| `teardown.sh`, `teardown.sql` | reverse all of it, including the AWR settings |

## The shape

| Phase | Schema | Users | Minutes | Exercises |
| --- | --- | --- | --- | --- |
| `ramp` | SOE | 4 | 45 | baseline OLTP, light growth |
| `peak` | SOE | 16 | 60 | CPU near `cpu_sat_pct`, order inserts grow `SOETBS` |
| `dss` | SH | 3 | 30 | query-heavy CPU, flat tablespace |
| `mixed` | SOE + SH | 8 + 2 | 45 | blended profile |
| `batch` | SOE (`PO`,`BO`,`WQ`,`WA`) | 6 | 20 | redo/undo heavy, few inserts |
| `anomaly` | SOE | 24 | 30 | deliberate CPU + growth outlier |

`run_phase.sh` forces an AWR snapshot either side of a phase, so phase
boundaries align with snapshot boundaries. Weekday-only phases self-skip at
weekends (`--force` overrides), and the phases that do run halve their user
count.

## Usage

```bash
cp bench/env.sh.example bench/env.sh && $EDITOR bench/env.sh   # once

./bench/setup/setup.sh                # AWR settings + tablespaces + both schemas
./bench/run_day.sh --short            # ~50 min smoke run
./bench/run_phase.sh peak             # a single phase
crontab bench/cron/bench.crontab      # daily shape from here on

./bench/teardown.sh                   # drop it all, restore AWR settings
```

Results land in `bench/results/<stamp>_<phase>.xml` and logs in `bench/logs/`
(both gitignored). `$SWINGBENCH_HOME/bin/results2pdf` turns a results file into
a report if you want the client-side view.

## Sizing notes

The test VM is small — **2 vCPU, 3 GB RAM, 1.5 GB SGA** — so it, not the
swingbench client, is the limit. Both schemas build at `-scale 1` (~1 GB each)
and `TBS_MAXSIZE` defaults to 6 GB per tablespace. The cap is deliberate:
`days_to_full` is only meaningful against a bounded tablespace. If `SOETBS`
grows too slowly to give a useful forecast, lower `TBS_MAXSIZE` rather than
pushing more concurrency at the VM.

## Reading the result

Install the toolkit in local mode where AWR lives (sysdba in `CDB$ROOT`), then:

```sql
-- did the load reach the seam?
SELECT * FROM capd_tbspc_daily WHERE tablespace_name = 'SOETBS' ORDER BY day_dt;
SELECT * FROM capd_cpu_daily ORDER BY day_dt;
```

Forecasts stay `INSUFFICIENT_HISTORY` until 14 daily points exist. To watch the
machinery earlier, temporarily lower the gate **on the test DB only**:

```sql
UPDATE cap_config SET cfg_value = 3 WHERE cfg_name = 'min_train_days';
COMMIT;   -- and put it back to 14 afterwards
```

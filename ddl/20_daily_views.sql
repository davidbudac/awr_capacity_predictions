--
-- ddl/20_daily_views.sql -- CAPD_* daily series over the CAPV_* seam.
-- =====================================================================
-- Collapses AWR snapshots (irregular, per-instance, cumulative-counter) into
-- clean one-row-per-day series that the forecast/anomaly layers fit. All
-- views are seam-agnostic: they touch only CAPV_*.
--
--   CAPD_TBSPC_DAILY   -- one row per (dbid, con_dbid, tablespace, day).
--                         Usage is a LEVEL, so we take the LAST sample of the
--                         day and convert blocks->bytes.
--   CAPD_TBSPC_DELTA   -- day-over-day used_bytes delta (negatives kept).
--   CAPD_COUNTER_DELTA -- every cumulative counter differenced once per
--                         interval, with the instance-restart flag.
--   CAPD_CPU_INTERVAL  -- one row per valid OSSTAT interval (busy / idle
--                         deltas side by side, restart intervals dropped).
--   CAPD_CPU_DAILY     -- host busy% per day over CAPD_CPU_INTERVAL; average +
--                         p95/max/peak-window variants (M10.1); AWR-gap
--                         columns (M10.5); day coverage (covered_sec /
--                         is_complete).
--   CAPD_DBTIME_INTERVAL -- the same for the time model, per container.
--   CAPD_DBTIME_DAILY  -- DB CPU / DB time / bg CPU seconds per day per
--                         container over CAPD_DBTIME_INTERVAL; DB CPU as % of
--                         the CPU ceiling (logical CPUs, or cpu_count when
--                         lower) + share of host (M10.2); the same gap and
--                         coverage columns.
--   CAPD_CPU_HOURLY    -- (M15) host BUSY_PCT and per-container DB_CPU_PCT per
--                         END-hour bucket over the two interval views; feeds
--                         the HOUR_OF_WEEK anomaly baseline.
--
-- 19c note: LAG uses an inline OVER (PARTITION BY ... ORDER BY ...) on every
-- call -- the standalone WINDOW clause is 21c+.
--
SET DEFINE OFF

-- --------------------------------------------------------------------
-- CAPD_TBSPC_DAILY
--   used_bytes  = last-of-day used blocks * block size
--   size_bytes  = last-of-day allocated blocks * block size
--   limit_bytes = maxsize*bs when autoextend on (maxsize>0), else size*bs,
--                 UNLESS a CAP_TBSPC_OVERRIDE row supplies a real ceiling
--   limit_source = OVERRIDE | AUTOEXTEND | ALLOCATED -- which of those three
--                 produced limit_bytes, carried all the way to the report
-- TBSPC_SPACE_USAGE carries no instance_number/timestamp, so we derive the
-- day by joining snap_id -> CAPV_SNAPSHOT (MIN end_interval_time across
-- instances for that snap). UNDO + TEMPORARY tablespaces are excluded
-- (their "usage" is transient and not a growth signal).
--
-- M9.5 overrides: CAP_TBSPC_OVERRIDE (dbid, con_dbid, tablespace_name) rows
-- either replace limit_bytes (autoextend maxsize is not real headroom when
-- the filesystem / ASM diskgroup behind it is smaller) or drop the tablespace
-- from the series entirely (exclude_flag = 'Y' -- staging / scratch). dbid = 0
-- and con_dbid = 0 are wildcards meaning "any"; when several rows match, the
-- `ores` CTE below keeps only the MOST SPECIFIC one (real dbid beats the
-- wildcard first, then real con_dbid), so exactly one override can apply per
-- tablespace and the LEFT JOIN cannot fan out. Applying it HERE -- the single
-- entry point to the daily series -- means every downstream layer (delta,
-- forecast, anomaly, alerts, reports) honours it with no further code.
-- The same row's alert thresholds ride along as ovr_dtf_warn / ovr_dtf_crit
-- / ovr_nearfull_warn_pct / ovr_nearfull_crit_pct (NULL = no override);
-- CAPF_TBSPC_FORECAST carries them and CAPR_SEVERITY applies them.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capd_tbspc_daily AS
WITH snap_time AS (
        SELECT dbid, snap_id, MIN(end_interval_time) AS end_interval_time
        FROM   capv_snapshot
        GROUP  BY dbid, snap_id
     ),
     bsize AS (
        SELECT dbid, con_dbid, tablespace_id, MAX(block_size) AS block_size
        FROM   capv_datafile
        GROUP  BY dbid, con_dbid, tablespace_id
     ),
     usg AS (
        SELECT u.dbid, u.con_dbid, u.tablespace_id,
               TRUNC(st.end_interval_time)  AS day_dt,
               st.end_interval_time         AS eit,
               u.tablespace_usedsize        AS used_blocks,
               u.tablespace_size            AS size_blocks,
               u.tablespace_maxsize         AS max_blocks
        FROM   capv_tbspc_usage u
        JOIN   snap_time st
          ON   st.dbid = u.dbid AND st.snap_id = u.snap_id
     ),
     -- M9.5: resolve at most ONE override row per (dbid, con_dbid, name).
     -- Built over the tablespace DIM (small) rather than the daily rows, so
     -- the ranking runs once per series, not once per day.
     ores AS (
        SELECT dbid, con_dbid, tablespace_name, limit_bytes, exclude_flag,
               dtf_warn, dtf_crit, nearfull_warn_pct, nearfull_crit_pct
        FROM (
            SELECT t.dbid, t.con_dbid, t.tablespace_name,
                   o.limit_bytes, o.exclude_flag,
                   o.dtf_warn, o.dtf_crit, o.nearfull_warn_pct, o.nearfull_crit_pct,
                   ROW_NUMBER() OVER (PARTITION BY t.dbid, t.con_dbid, t.tablespace_name
                                      ORDER BY CASE WHEN o.dbid     <> 0 THEN 0 ELSE 1 END,
                                               CASE WHEN o.con_dbid <> 0 THEN 0 ELSE 1 END) AS rn
            FROM   (SELECT DISTINCT dbid, con_dbid, tablespace_name FROM capv_tablespace) t
            JOIN   cap_tbspc_override o
              ON   o.tablespace_name = t.tablespace_name
             AND   (o.dbid     = t.dbid     OR o.dbid     = 0)
             AND   (o.con_dbid = t.con_dbid OR o.con_dbid = 0)
        )
        WHERE rn = 1
     ),
     last_of_day AS (
        SELECT dbid, con_dbid, tablespace_id, day_dt,
               MAX(used_blocks) KEEP (DENSE_RANK LAST ORDER BY eit) AS used_blocks,
               MAX(size_blocks) KEEP (DENSE_RANK LAST ORDER BY eit) AS size_blocks,
               MAX(max_blocks)  KEEP (DENSE_RANK LAST ORDER BY eit) AS max_blocks,
               COUNT(*)                                             AS n_samples
        FROM   usg
        GROUP  BY dbid, con_dbid, tablespace_id, day_dt
     )
SELECT l.dbid,
       l.con_dbid,
       t.tablespace_name,
       t.contents,
       l.day_dt,
       l.used_blocks * COALESCE(t.block_size, b.block_size)  AS used_bytes,
       l.size_blocks * COALESCE(t.block_size, b.block_size)  AS size_bytes,
       NVL(o.limit_bytes,
           CASE WHEN l.max_blocks > 0
                THEN l.max_blocks  * COALESCE(t.block_size, b.block_size)
                ELSE l.size_blocks * COALESCE(t.block_size, b.block_size)
           END)                                              AS limit_bytes,
       CASE WHEN o.limit_bytes IS NOT NULL THEN 'OVERRIDE'
            WHEN l.max_blocks > 0          THEN 'AUTOEXTEND'
            ELSE                                'ALLOCATED'
       END                                                   AS limit_source,
       COALESCE(t.block_size, b.block_size)                  AS block_size,
       l.n_samples,
       o.dtf_warn                                            AS ovr_dtf_warn,
       o.dtf_crit                                            AS ovr_dtf_crit,
       o.nearfull_warn_pct                                   AS ovr_nearfull_warn_pct,
       o.nearfull_crit_pct                                   AS ovr_nearfull_crit_pct
FROM   last_of_day l
JOIN   capv_tablespace t
  ON   t.dbid = l.dbid AND t.con_dbid = l.con_dbid AND t.tablespace_id = l.tablespace_id
-- Datafile block size is only a FALLBACK; DBA_HIST_DATAFILE can lack rows
-- (SYSTEM is absent on stock 19c), so a LEFT JOIN + COALESCE onto the
-- tablespace dim's block_size keeps every permanent tablespace in the series.
LEFT   JOIN bsize b
  ON   b.dbid = l.dbid AND b.con_dbid = l.con_dbid AND b.tablespace_id = l.tablespace_id
-- M9.5: at most one row per series by construction (ores keeps rn = 1).
LEFT   JOIN ores o
  ON   o.dbid = l.dbid AND o.con_dbid = l.con_dbid AND o.tablespace_name = t.tablespace_name
WHERE  t.contents NOT IN ('UNDO','TEMPORARY')
  AND  COALESCE(t.block_size, b.block_size) IS NOT NULL
  AND  NVL(o.exclude_flag, 'N') = 'N';

-- --------------------------------------------------------------------
-- CAPD_TBSPC_DELTA -- change since the previous SAMPLED day. Negative deltas
-- (purge / shrink / reorg) are legitimate signals and are kept.
--   day_gap        = calendar days since the previous sample (1 if consecutive,
--                    >1 across an AWR gap / instance downtime).
--   used_delta_bytes = raw change over that (possibly multi-day) gap.
--   used_rate_bpd  = used_delta_bytes / day_gap -- the per-day growth RATE, so a
--                    multi-day gap is not mistaken for a one-day spike. The
--                    anomaly layer keys off this rate, not the raw delta.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capd_tbspc_delta AS
SELECT dbid, con_dbid, tablespace_name, contents, day_dt, used_bytes, limit_bytes,
       used_delta_bytes,
       day_gap,
       CASE WHEN day_gap > 0 THEN used_delta_bytes / day_gap END AS used_rate_bpd
FROM (
    SELECT d.dbid,
           d.con_dbid,
           d.tablespace_name,
           d.contents,
           d.day_dt,
           d.used_bytes,
           d.limit_bytes,
           d.used_bytes
             - LAG(d.used_bytes) OVER (PARTITION BY d.dbid, d.con_dbid, d.tablespace_name
                                       ORDER BY d.day_dt)  AS used_delta_bytes,
           d.day_dt
             - LAG(d.day_dt)    OVER (PARTITION BY d.dbid, d.con_dbid, d.tablespace_name
                                       ORDER BY d.day_dt)  AS day_gap
    FROM   capd_tbspc_daily d
);

-- --------------------------------------------------------------------
-- CAPD_COUNTER_DELTA -- every cumulative counter the suite reads, differenced
-- once. One row per (dbid, con_dbid, instance, source, stat_name, interval):
--   source      OSSTAT     BUSY_TIME / IDLE_TIME / IOWAIT_TIME (centiseconds)
--               TIME_MODEL DB CPU / DB time / background cpu time (microseconds)
--               SYSSTAT    every CAPV_SYSSTAT name, consumers filter
--                          (local / warehouse: 'redo size', bytes)
--   delta       value - previous value of the same counter, by snap_id
--   ivl_sec     end_time - prev_end_time in whole seconds
--   is_restart  'Y' when the interval spans an instance startup (startup_time
--               differs from the previous snapshot's) or the delta is
--               negative (counter reset), else 'N'. Consumers keep 'N' only.
-- The first snapshot of each partition has no predecessor and no row. A NULL
-- value gives a NULL delta, which every consumer drops.
-- NULL startup_time: DECODE treats two NULLs as equal, so a source that never
-- fills startup_time (possible in a warehouse) keeps its intervals, and only a
-- NULL-to-value change counts as a restart. A plain startup_time =
-- prev_startup test is never true for NULLs and emptied such a series.
-- A delta is attributed to the day its interval ENDS on, everywhere.
-- CAPD_CPU_INTERVAL, CAPD_DBTIME_INTERVAL and the REDO_GB_DAY branch of
-- CAPD_SERIES_DAILY pivot these rows per interval instead of each running
-- its own LAG. They group by prev_end_time too, so two counters only pair up
-- when they difference the same pair of snapshots.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capd_counter_delta AS
WITH ctr AS (
        SELECT 'OSSTAT' AS source, dbid, con_dbid, instance_number, snap_id, stat_name, value
        FROM   capv_osstat
        WHERE  stat_name IN ('BUSY_TIME','IDLE_TIME','IOWAIT_TIME')
        UNION ALL
        SELECT 'TIME_MODEL', dbid, con_dbid, instance_number, snap_id, stat_name, value
        FROM   capv_time_model
        UNION ALL
        SELECT 'SYSSTAT', dbid, con_dbid, instance_number, snap_id, stat_name, value
        FROM   capv_sysstat
     ),
     lagged AS (
        -- CAPV_SNAPSHOT sets con_dbid := dbid, so the join is on (dbid,
        -- snap_id, instance_number) and con_dbid comes from the counter.
        SELECT c.source, c.dbid, c.con_dbid, c.instance_number, c.stat_name, c.snap_id,
               c.value,
               s.end_interval_time AS end_time,
               s.startup_time,
               LAG(c.snap_id)
                 OVER (PARTITION BY c.source, c.dbid, c.con_dbid, c.instance_number, c.stat_name
                       ORDER BY c.snap_id) AS prev_snap_id,
               LAG(c.value)
                 OVER (PARTITION BY c.source, c.dbid, c.con_dbid, c.instance_number, c.stat_name
                       ORDER BY c.snap_id) AS prev_value,
               LAG(s.end_interval_time)
                 OVER (PARTITION BY c.source, c.dbid, c.con_dbid, c.instance_number, c.stat_name
                       ORDER BY c.snap_id) AS prev_end_time,
               LAG(s.startup_time)
                 OVER (PARTITION BY c.source, c.dbid, c.con_dbid, c.instance_number, c.stat_name
                       ORDER BY c.snap_id) AS prev_startup
        FROM   ctr c
        JOIN   capv_snapshot s
          ON   s.dbid = c.dbid AND s.snap_id = c.snap_id
         AND   s.instance_number = c.instance_number
     )
SELECT dbid,
       con_dbid,
       instance_number,
       source,
       stat_name,
       snap_id,
       end_time,
       prev_end_time,
       -- DATE arithmetic gives days. AWR times have whole-second resolution,
       -- so ROUND only removes the 1/86400 representation error.
       ROUND((CAST(end_time AS DATE) - CAST(prev_end_time AS DATE)) * 86400) AS ivl_sec,
       value - prev_value                                                   AS delta,
       startup_time,
       CASE WHEN DECODE(startup_time, prev_startup, 0, 1) = 1 THEN 'Y'
            WHEN value < prev_value                         THEN 'Y'
            ELSE 'N'
       END                                                                  AS is_restart
FROM   lagged
WHERE  prev_snap_id IS NOT NULL;

-- --------------------------------------------------------------------
-- CAPD_CPU_INTERVAL -- one row per VALID OSSTAT interval per instance: the
-- BUSY_TIME / IDLE_TIME deltas of CAPD_COUNTER_DELTA side by side. An
-- interval is valid when both deltas exist and neither is a restart
-- (startup_time changed, or a negative delta): either would corrupt the
-- ratio. CAPD_CPU_DAILY and CAPD_CPU_HOURLY aggregate this row set, so the
-- day and the hour grain cannot disagree on which intervals count.
--   snap_id       = the interval's END snapshot; end_time its end.
--   day_dt        = TRUNC(end_time): an interval belongs to the day it ENDS
--                   on (the suite-wide rule).
--   hour_ts       = the clock hour the interval ends at. The -5 min absorbs
--                   AWR flush jitter (10:00:03 and 09:59:58 both -> 10:00),
--                   the +1 h labels the bucket by its END.
--   ivl_sec / ivl_hours = interval length.
--   num_cpus / num_cpu_cores = the levels read at the end snapshot.
--   is_long       = 1 when ivl_hours > cpu_gap_hours (M10.5 day-grain gap).
--   typ_ivl_hours = this instance's MEDIAN interval length (its AWR cadence).
--   is_gap_hour   = 1 when the interval is unusable at HOUR grain: <= 0 h (a
--                   DST fall-back or clock step) or longer than
--                   LEAST(cpu_gap_hours, hour_gap_ratio * typ_ivl_hours).
--                   Hourly AWR: anything over 1.5 h. Never more lenient than
--                   the day rule, so 12 h snapshots (the fixture) gap only
--                   above 12 h.
--   ivl_busy_pct  = per-interval busy%, NULL for an interval longer than
--                   cpu_gap_hours so it drops out of PERCENTILE_CONT / MAX
--                   (both ignore NULLs) instead of diluting a day's peak.
--   in_peak       = end hour in (peak_hour_from, peak_hour_to] and not
--                   longer than cpu_gap_hours.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capd_cpu_interval AS
WITH ivl AS (
        SELECT d.dbid, d.con_dbid, d.instance_number, d.snap_id, d.end_time, d.ivl_sec,
               MAX(CASE WHEN d.stat_name = 'BUSY_TIME' THEN d.delta END) AS busy_d,
               MAX(CASE WHEN d.stat_name = 'IDLE_TIME' THEN d.delta END) AS idle_d,
               MAX(d.is_restart)                                         AS is_restart
        FROM   capd_counter_delta d
        WHERE  d.source = 'OSSTAT'
          AND  d.stat_name IN ('BUSY_TIME','IDLE_TIME')
        GROUP  BY d.dbid, d.con_dbid, d.instance_number, d.snap_id,
                  d.end_time, d.prev_end_time, d.ivl_sec
     ),
     lvl AS (
        -- CPU counts are levels, read at the end snapshot of the interval.
        SELECT dbid, con_dbid, instance_number, snap_id,
               MAX(CASE WHEN stat_name = 'NUM_CPUS'      THEN value END) AS num_cpus,
               MAX(CASE WHEN stat_name = 'NUM_CPU_CORES' THEN value END) AS num_cpu_cores
        FROM   capv_osstat
        WHERE  stat_name IN ('NUM_CPUS','NUM_CPU_CORES')
        GROUP  BY dbid, con_dbid, instance_number, snap_id
     ),
     valid AS (
        SELECT i.dbid, i.con_dbid, i.instance_number, i.snap_id, i.end_time,
               TRUNC(i.end_time)                                       AS day_dt,
               TRUNC(CAST(i.end_time AS DATE) - 5/1440, 'HH24') + 1/24 AS hour_ts,
               i.busy_d, i.idle_d, l.num_cpus, l.num_cpu_cores,
               i.ivl_sec,
               i.ivl_sec / 3600                                        AS ivl_hours
        FROM   ivl i
        LEFT   JOIN lvl l
          ON   l.dbid = i.dbid AND l.con_dbid = i.con_dbid
         AND   l.instance_number = i.instance_number AND l.snap_id = i.snap_id
        WHERE  i.busy_d IS NOT NULL AND i.idle_d IS NOT NULL
          AND  i.is_restart = 'N'
     )
SELECT v.dbid,
       v.con_dbid,
       v.instance_number,
       v.snap_id,
       v.end_time,
       v.day_dt,
       v.hour_ts,
       v.ivl_sec,
       v.ivl_hours,
       v.busy_d,
       v.idle_d,
       v.num_cpus,
       v.num_cpu_cores,
       CASE WHEN v.ivl_hours > cfg.cpu_gap_hours THEN 1 ELSE 0 END          AS is_long,
       MEDIAN(v.ivl_hours) OVER (PARTITION BY v.dbid, v.con_dbid, v.instance_number) AS typ_ivl_hours,
       CASE WHEN v.ivl_hours <= 0
              OR v.ivl_hours > LEAST(cfg.cpu_gap_hours,
                                     cfg.hour_gap_ratio
                                     * MEDIAN(v.ivl_hours) OVER (PARTITION BY v.dbid, v.con_dbid, v.instance_number))
            THEN 1 ELSE 0 END                                               AS is_gap_hour,
       CASE WHEN v.ivl_hours <= cfg.cpu_gap_hours
            THEN 100 * v.busy_d / NULLIF(v.busy_d + v.idle_d, 0)
       END                                                                  AS ivl_busy_pct,
       CASE WHEN EXTRACT(HOUR FROM CAST(v.end_time AS TIMESTAMP)) >  cfg.peak_hour_from
             AND EXTRACT(HOUR FROM CAST(v.end_time AS TIMESTAMP)) <= cfg.peak_hour_to
             AND v.ivl_hours <= cfg.cpu_gap_hours
            THEN 1 ELSE 0 END                                               AS in_peak
FROM   valid v
CROSS  JOIN cap_cfg cfg;

-- --------------------------------------------------------------------
-- CAPD_CPU_DAILY -- host CPU busy% per day: average AND peak (M10.1), one
-- GROUP BY over CAPD_CPU_INTERVAL (BUSY_TIME / IDLE_TIME are centisecond
-- counters; the units cancel in every ratio, so no conversion is needed).
--   busy_pct      = 100 * SUM(busy_d) / SUM(busy_d+idle_d) over the day
--                   (time-weighted daily average -- the "average" view).
--   busy_p95      = PERCENTILE_CONT(0.95) of the per-INTERVAL busy% within
--                   the day; busy_max = the busiest single interval. With
--                   hourly AWR these are "the busy hour", which is what
--                   actually saturates -- a 40% daily average can hide a
--                   95% peak hour.
--   busy_peak_pct = time-weighted busy% over only the intervals whose
--                   end_interval_time hour falls in (peak_hour_from,
--                   peak_hour_to] (CAP_CONFIG; default (8,18] = the hourly
--                   snapshots ending 09:00..18:00). NULL when no interval of
--                   the day ends inside the window. peak_intervals counts them.
--   host_busy_sec = SUM(busy_d)/100: host busy CPU-seconds that day, summed
--                   across instances -- the denominator for a container's
--                   share of host CPU (CAPD_DBTIME_DAILY.host_share_pct).
-- Per-interval busy% in a RAC/multi-instance setup is per instance; p95/max
-- are taken over all (instance, interval) pairs of the day.
--
-- M10.5 -- AWR GAPS. A missing stretch of snapshots does not create a hole in
-- the counter series: the next snapshot simply differences against a much
-- older one, and that ONE long interval is attributed to the day it ends on.
-- A 36 h interval's average is not a day, and it is certainly not a "peak
-- hour". So, mirroring CAPD_TBSPC_DELTA.day_gap:
--   max_interval_hours = the longest interval ending that day (hours).
--   gap_flag           = 'Y' when max_interval_hours > cpu_gap_hours (knob).
--   day_gap            = calendar days since the previous day that HAS a row
--                        (1 = consecutive, >1 across a gap / downtime).
-- The day is KEPT in the series (it is still data, and the forecast layer
-- wants it), but:
--   * busy_p95 / busy_max / busy_peak_pct are computed only from intervals
--     <= cpu_gap_hours, so a multi-day average can never masquerade as a peak
--     hour. If the day has no short interval at all they are NULL.
--   * CAPA_ANOM (ddl/40) drops gap_flag='Y' days from every baseline and
--     never flags one, and CAPA_CPU_SHIFT skips them too.
-- busy_pct itself still uses EVERY valid interval, so the day's time-weighted
-- average stays honest about the counters that were actually recorded.
-- Restart intervals are dropped before max_interval_hours is taken, so a
-- restart or outage day keeps gap_flag = 'N'. covered_sec says how much of
-- the day the valid intervals cover:
--   covered_sec = valid interval seconds ending that day, per instance (the
--                 sum divided by the instances that reported). 86400 for a
--                 full day, less on the first day of AWR history, on today's
--                 partial day and on a restart day. More than 86400 on a gap
--                 day, whose long interval also covers earlier days.
--   is_complete = 'Y' when covered_sec >= complete_day_pct (knob, default
--                 80) percent of 86400, else 'N'.
-- num_cpus / num_cpu_cores are the day's averages over its intervals.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capd_cpu_daily AS
WITH agg AS (
        SELECT dbid,
               con_dbid,
               day_dt,
               100 * SUM(busy_d) / NULLIF(SUM(busy_d) + SUM(idle_d), 0)      AS busy_pct,
               PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY ivl_busy_pct)    AS busy_p95,
               MAX(ivl_busy_pct)                                             AS busy_max,
               100 * SUM(CASE WHEN in_peak = 1 THEN busy_d END)
                   / NULLIF(SUM(CASE WHEN in_peak = 1 THEN busy_d + idle_d END), 0) AS busy_peak_pct,
               SUM(in_peak)                                                  AS peak_intervals,
               SUM(busy_d) / 100                                             AS host_busy_sec,
               ROUND(AVG(num_cpus))                                          AS num_cpus,
               ROUND(AVG(num_cpu_cores))                                     AS num_cpu_cores,
               COUNT(*)                                                      AS n_intervals,
               ROUND(MAX(ivl_hours), 2)                                      AS max_interval_hours,
               CASE WHEN MAX(is_long) = 1 THEN 'Y' ELSE 'N' END              AS gap_flag,
               SUM(ivl_sec) / COUNT(DISTINCT instance_number)                AS covered_sec
        FROM   capd_cpu_interval
        GROUP  BY dbid, con_dbid, day_dt
     )
SELECT a.dbid,
       a.con_dbid,
       a.day_dt,
       a.busy_pct,
       a.busy_p95,
       a.busy_max,
       a.busy_peak_pct,
       a.peak_intervals,
       a.host_busy_sec,
       a.num_cpus,
       a.num_cpu_cores,
       a.n_intervals,
       a.max_interval_hours,
       a.gap_flag,
       a.day_dt - LAG(a.day_dt) OVER (PARTITION BY a.dbid, a.con_dbid
                                      ORDER BY a.day_dt)                     AS day_gap,
       a.covered_sec,
       CASE WHEN a.covered_sec >= cfg.complete_day_pct / 100 * 86400
            THEN 'Y' ELSE 'N' END                                            AS is_complete
FROM   agg a
CROSS  JOIN cap_cfg cfg;

-- --------------------------------------------------------------------
-- CAPD_DBTIME_INTERVAL -- one row per VALID time-model interval per
-- (container, instance): the DB CPU / DB time / background cpu time deltas
-- of CAPD_COUNTER_DELTA side by side, valid by the same rule as
-- CAPD_CPU_INTERVAL (DB CPU and DB time present, no restart). Carries the
-- same day_dt / hour_ts / ivl_hours / is_long / typ_ivl_hours /
-- is_gap_hour / in_peak columns. CAPD_DBTIME_DAILY and CAPD_CPU_HOURLY
-- aggregate this row set.
--   num_cpus      = logical CPUs of the instance at the interval's end
--                   snapshot (NUM_CPUS, else NUM_CPU_CORES). OSSTAT is host
--                   level and recorded under the CDB's con_dbid, so it is
--                   matched on (dbid, instance, snap_id) and serves every
--                   container. A snapshot with no OSSTAT row uses the
--                   instance's last earlier value.
--   cpu_count     = the cpu_count init parameter (CAPV_PARAMETER) at the
--                   interval's end snapshot; NULL when AWR has no row there
--                   (not carried forward).
--   cpu_ceiling   = LEAST(num_cpus, cpu_count), the one that is known when
--                   the other is NULL. See CAPD_DBTIME_DAILY.
--   cap_sec       = cpu_ceiling * ivl_sec, the CPU seconds the interval
--                   offered the instance; NULL when unknown. cpu_count
--                   defaults to the logical CPU count, so this is
--                   num_cpus * ivl_sec unless the instance is caged.
--   total_cores   = host cores summed across instances (MAX over the dbid's
--                   history, NUM_CPU_CORES falling back to NUM_CPUS).
--   ivl_cpu_pct   = DB CPU seconds / cap_sec, NULL for an interval longer
--                   than cpu_gap_hours.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capd_dbtime_interval AS
WITH ivl AS (
        SELECT d.dbid, d.con_dbid, d.instance_number, d.snap_id, d.end_time, d.ivl_sec,
               MAX(CASE WHEN d.stat_name = 'DB CPU'              THEN d.delta END) AS db_cpu_d,
               MAX(CASE WHEN d.stat_name = 'DB time'             THEN d.delta END) AS db_time_d,
               MAX(CASE WHEN d.stat_name = 'background cpu time' THEN d.delta END) AS bg_cpu_d,
               MAX(d.is_restart)                                                   AS is_restart
        FROM   capd_counter_delta d
        WHERE  d.source = 'TIME_MODEL'
        GROUP  BY d.dbid, d.con_dbid, d.instance_number, d.snap_id,
                  d.end_time, d.prev_end_time, d.ivl_sec
     ),
     ncpu AS (
        -- Logical CPUs per instance at every snapshot, carried forward over
        -- snapshots that have no OSSTAT row.
        SELECT s.dbid, s.instance_number, s.snap_id,
               LAST_VALUE(o.num_cpus IGNORE NULLS)
                 OVER (PARTITION BY s.dbid, s.instance_number ORDER BY s.snap_id
                       ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS num_cpus,
               LAST_VALUE(o.num_cpu_cores IGNORE NULLS)
                 OVER (PARTITION BY s.dbid, s.instance_number ORDER BY s.snap_id
                       ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS num_cpu_cores
        FROM   capv_snapshot s
        LEFT   JOIN ( SELECT dbid, instance_number, snap_id,
                             NVL(MAX(CASE WHEN stat_name = 'NUM_CPUS'      THEN value END),
                                 MAX(CASE WHEN stat_name = 'NUM_CPU_CORES' THEN value END)) AS num_cpus,
                             MAX(CASE WHEN stat_name = 'NUM_CPU_CORES' THEN value END)     AS num_cpu_cores
                      FROM   capv_osstat
                      WHERE  stat_name IN ('NUM_CPUS','NUM_CPU_CORES')
                      GROUP  BY dbid, instance_number, snap_id ) o
          ON   o.dbid = s.dbid AND o.instance_number = s.instance_number AND o.snap_id = s.snap_id
     ),
     cores AS (
        SELECT dbid,
               SUM(ncore) AS total_cores
        FROM ( SELECT dbid, instance_number,
                      NVL(MAX(CASE WHEN stat_name = 'NUM_CPU_CORES' THEN value END),
                          MAX(CASE WHEN stat_name = 'NUM_CPUS'      THEN value END)) AS ncore
               FROM   capv_osstat
               GROUP  BY dbid, instance_number )
        GROUP BY dbid
     ),
     -- cpu_count at the interval's end snapshot, like num_cpus. Joined here
     -- and not carried forward inside ncpu: a second windowed column there
     -- made the optimizer push the interval join into ncpu and re-run it per
     -- interval (the 150-day demo: minutes instead of a second).
     ivc AS (
        SELECT i.*,
               n.num_cpus, n.num_cpu_cores, pc.cpu_count,
               COALESCE(LEAST(n.num_cpus, pc.cpu_count), n.num_cpus, pc.cpu_count) AS cpu_ceiling
        FROM   ivl i
        LEFT   JOIN ncpu n
          ON   n.dbid = i.dbid AND n.instance_number = i.instance_number AND n.snap_id = i.snap_id
        LEFT   JOIN ( SELECT dbid, instance_number, snap_id,
                             MAX(CASE WHEN value_num > 0 THEN value_num END) AS cpu_count
                      FROM   capv_parameter
                      WHERE  parameter_name = 'cpu_count'
                      GROUP  BY dbid, instance_number, snap_id ) pc
          ON   pc.dbid = i.dbid AND pc.instance_number = i.instance_number AND pc.snap_id = i.snap_id
        WHERE  i.db_cpu_d IS NOT NULL AND i.db_time_d IS NOT NULL
          AND  i.is_restart = 'N'
     ),
     valid AS (
        SELECT i.dbid, i.con_dbid, i.instance_number, i.snap_id, i.end_time,
               TRUNC(i.end_time)                                       AS day_dt,
               TRUNC(CAST(i.end_time AS DATE) - 5/1440, 'HH24') + 1/24 AS hour_ts,
               i.db_cpu_d, i.db_time_d, i.bg_cpu_d, i.ivl_sec,
               i.ivl_sec / 3600                                        AS ivl_hours,
               i.num_cpus, i.num_cpu_cores, i.cpu_count, i.cpu_ceiling,
               CASE WHEN i.cpu_ceiling > 0 AND i.ivl_sec > 0
                    THEN i.cpu_ceiling * i.ivl_sec
               END                                                     AS cap_sec,
               c.total_cores
        FROM   ivc i
        LEFT   JOIN cores c ON c.dbid = i.dbid
     )
SELECT v.dbid,
       v.con_dbid,
       v.instance_number,
       v.snap_id,
       v.end_time,
       v.day_dt,
       v.hour_ts,
       v.ivl_sec,
       v.ivl_hours,
       v.db_cpu_d,
       v.db_time_d,
       v.bg_cpu_d,
       v.num_cpus,
       v.num_cpu_cores,
       v.cap_sec,
       v.total_cores,
       CASE WHEN v.ivl_hours > cfg.cpu_gap_hours THEN 1 ELSE 0 END          AS is_long,
       MEDIAN(v.ivl_hours) OVER (PARTITION BY v.dbid, v.con_dbid, v.instance_number) AS typ_ivl_hours,
       CASE WHEN v.ivl_hours <= 0
              OR v.ivl_hours > LEAST(cfg.cpu_gap_hours,
                                     cfg.hour_gap_ratio
                                     * MEDIAN(v.ivl_hours) OVER (PARTITION BY v.dbid, v.con_dbid, v.instance_number))
            THEN 1 ELSE 0 END                                               AS is_gap_hour,
       CASE WHEN v.cap_sec IS NOT NULL AND v.ivl_hours <= cfg.cpu_gap_hours
            THEN 100 * (v.db_cpu_d / 1e6) / v.cap_sec
       END                                                                  AS ivl_cpu_pct,
       CASE WHEN EXTRACT(HOUR FROM CAST(v.end_time AS TIMESTAMP)) >  cfg.peak_hour_from
             AND EXTRACT(HOUR FROM CAST(v.end_time AS TIMESTAMP)) <= cfg.peak_hour_to
             AND v.ivl_hours <= cfg.cpu_gap_hours
            THEN 1 ELSE 0 END                                               AS in_peak,
       v.cpu_count,
       v.cpu_ceiling
FROM   valid v
CROSS  JOIN cap_cfg cfg;

-- --------------------------------------------------------------------
-- CAPD_DBTIME_DAILY -- DB CPU / DB time / background CPU seconds per day per
-- container, DB CPU as a PERCENT OF LOGICAL-CPU CAPACITY (M10.2) and the
-- container's share of host CPU.
-- One GROUP BY over CAPD_DBTIME_INTERVAL (cumulative MICROSECOND counters),
-- summed across instances per day and divided by 1e6 to seconds.
--   db_cpu_pct      = 100 * db_cpu_sec / SUM over the day's valid intervals
--                     of (cpu_ceiling * ivl_sec): the share of the CPU
--                     seconds the instance may use that this container's
--                     foreground DB CPU used while the counters were
--                     recording. cpu_ceiling is num_cpus unless cpu_count is
--                     lower (below).
--                     Why logical CPUs: Oracle accrues CPU time per logical
--                     CPU (a thread on an SMT host), OSSTAT BUSY_TIME /
--                     IDLE_TIME are summed over NUM_CPUS, and the AWR report's
--                     own %Total CPU divides by NUM_CPUS. Dividing by cores
--                     read 2x on 2-way SMT (4-8x on POWER / SPARC) and fired
--                     DBCPU_SAT at half load. With cpu_ceiling = num_cpus,
--                     db_cpu_pct = busy_pct * host_share_pct / 100, the same
--                     scale as host busy%.
--                     num_cpus is read per interval at its end snapshot
--                     (NUM_CPUS, else NUM_CPU_CORES), so a host resize does
--                     not rewrite history. OSSTAT is host level and recorded
--                     under the CDB's con_dbid, so it is matched on (dbid,
--                     instance, snap_id) and serves every container. A
--                     snapshot with no OSSTAT row uses the instance's last
--                     earlier value.
--                     The denominator is the covered time, not 86400, so a
--                     partial, restart or gap day reads its true average.
--   cpu_count / cpu_ceiling
--                   = the cpu_count init parameter (CAPV_PARAMETER) and
--                     LEAST(num_cpus, cpu_count). With a Resource Manager
--                     plan active, cpu_count cages the instance (instance
--                     caging), so an instance with cpu_count 4 on a 16-CPU
--                     host saturates at 4 CPUs and db_cpu_pct reads against
--                     4. With no plan the cage is not enforced and
--                     db_cpu_pct can pass 100, which says the instance uses
--                     more CPU than it is configured for. cpu_count
--                     defaults to the logical CPU count, so on most systems
--                     cpu_ceiling = num_cpus and nothing changes. Read at
--                     the interval's end snapshot. Unlike num_cpus it is not
--                     carried forward (AWR records the parameters at every
--                     snapshot), so an interval with no cpu_count row uses
--                     num_cpus alone, and a NULL num_cpus uses cpu_count.
--                     The day columns are the day's MAX per instance, summed
--                     across instances. Root-level cpu_count only: a
--                     PDB-level CPU_COUNT is not read.
--   db_cpu_p95_pct / db_cpu_max_pct / db_cpu_peak_pct
--                   = the per-INTERVAL version of db_cpu_pct (DB CPU seconds
--                     over the interval's cpu_ceiling * ivl_sec), then p95 / max
--                     over the day / time-weighted over the peak window (same
--                     (peak_hour_from, peak_hour_to] rule as CAPD_CPU_DAILY).
--                     Per-PDB "busy hour".
--   db_cpu_per_core = db_cpu_sec / total_cores, where total_cores is the
--                     host core count summed across instances (MAX over the
--                     dbid's history, NUM_CPU_CORES falling back to NUM_CPUS),
--                     so it is comparable across differently-sized hosts.
--   num_cpus / num_cpu_cores
--                   = the day's MAX over its intervals per instance, summed
--                     across instances, so a resize shows on the day it lands.
--   host_share_pct  = 100 * db_cpu_sec / host busy seconds that day (host
--                     busy from CAPD_CPU_DAILY summed over the dbid, since
--                     OSSTAT records under the CDB's con_dbid): how much of
--                     what the host was doing was THIS container.
--   max_interval_hours / gap_flag / day_gap / covered_sec / is_complete
--                   = identical in meaning to CAPD_CPU_DAILY's (see the
--                     comment block there). The per-interval percentages
--                     ignore intervals longer than cpu_gap_hours. The daily
--                     totals do not, and on a gap day db_cpu_sec carries more
--                     than a day of CPU (gap_flag says so) while db_cpu_pct
--                     stays an average over the covered time.
-- In local mode the root row is CDB$ROOT alone (see ddl/10). The CDB's total
-- DB CPU is the SUM over its containers.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capd_dbtime_daily AS
WITH ivl AS (
        -- Named once and read twice (cpus_day, agg) so Oracle materializes it:
        -- two direct view references let it push the day predicate into
        -- CAPD_DBTIME_INTERVAL per row and re-sort the counters each time.
        SELECT * FROM capd_dbtime_interval
     ),
     host AS (
        SELECT dbid, day_dt, SUM(host_busy_sec) AS host_busy_sec
        FROM   capd_cpu_daily
        GROUP  BY dbid, day_dt
     ),
     -- CPU counts per day: MAX per instance, then summed across instances
     cpus_day AS (
        SELECT dbid, con_dbid, day_dt,
               SUM(num_cpus)      AS num_cpus,
               SUM(num_cpu_cores) AS num_cpu_cores,
               SUM(cpu_count)     AS cpu_count,
               SUM(cpu_ceiling)   AS cpu_ceiling
        FROM ( SELECT dbid, con_dbid, day_dt, instance_number,
                      MAX(num_cpus)      AS num_cpus,
                      MAX(num_cpu_cores) AS num_cpu_cores,
                      MAX(cpu_count)     AS cpu_count,
                      MAX(cpu_ceiling)   AS cpu_ceiling
               FROM   ivl
               GROUP  BY dbid, con_dbid, day_dt, instance_number )
        GROUP  BY dbid, con_dbid, day_dt
     ),
     agg AS (
        SELECT v.dbid,
               v.con_dbid,
               v.day_dt,
               SUM(v.db_cpu_d)  / 1e6                              AS db_cpu_sec,
               SUM(v.db_time_d) / 1e6                              AS db_time_sec,
               SUM(v.bg_cpu_d)  / 1e6                              AS bg_cpu_sec,
               CASE WHEN v.total_cores > 0
                    THEN (SUM(v.db_cpu_d) / 1e6) / v.total_cores
               END                                                 AS db_cpu_per_core,
               100 * (SUM(CASE WHEN v.cap_sec IS NOT NULL THEN v.db_cpu_d END) / 1e6)
                   / NULLIF(SUM(v.cap_sec), 0)                     AS db_cpu_pct,
               PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY v.ivl_cpu_pct) AS db_cpu_p95_pct,
               MAX(v.ivl_cpu_pct)                                  AS db_cpu_max_pct,
               100 * (SUM(CASE WHEN v.in_peak = 1 AND v.cap_sec IS NOT NULL THEN v.db_cpu_d END) / 1e6)
                   / NULLIF(SUM(CASE WHEN v.in_peak = 1 THEN v.cap_sec END), 0) AS db_cpu_peak_pct,
               SUM(v.in_peak)                                      AS peak_intervals,
               CASE WHEN h.host_busy_sec > 0
                    THEN 100 * (SUM(v.db_cpu_d) / 1e6) / h.host_busy_sec
               END                                                 AS host_share_pct,
               v.total_cores,
               COUNT(*)                                            AS n_intervals,
               ROUND(MAX(v.ivl_hours), 2)                          AS max_interval_hours,
               CASE WHEN MAX(v.is_long) = 1 THEN 'Y' ELSE 'N' END   AS gap_flag,
               SUM(v.ivl_sec) / COUNT(DISTINCT v.instance_number)  AS covered_sec
        FROM   ivl v
        LEFT   JOIN host h ON h.dbid = v.dbid AND h.day_dt = v.day_dt
        GROUP  BY v.dbid, v.con_dbid, v.day_dt, v.total_cores, h.host_busy_sec
     )
SELECT a.dbid,
       a.con_dbid,
       a.day_dt,
       a.db_cpu_sec,
       a.db_time_sec,
       a.bg_cpu_sec,
       a.db_cpu_per_core,
       a.db_cpu_pct,
       a.db_cpu_p95_pct,
       a.db_cpu_max_pct,
       a.db_cpu_peak_pct,
       a.peak_intervals,
       a.host_share_pct,
       a.total_cores,
       a.n_intervals,
       a.max_interval_hours,
       a.gap_flag,
       a.day_dt - LAG(a.day_dt) OVER (PARTITION BY a.dbid, a.con_dbid
                                      ORDER BY a.day_dt)           AS day_gap,
       c.num_cpus,
       c.num_cpu_cores,
       a.covered_sec,
       CASE WHEN a.covered_sec >= cfg.complete_day_pct / 100 * 86400
            THEN 'Y' ELSE 'N' END                                  AS is_complete,
       c.cpu_count,
       c.cpu_ceiling
FROM   agg a
JOIN   cpus_day c
  ON   c.dbid = a.dbid AND c.con_dbid = a.con_dbid AND c.day_dt = a.day_dt
CROSS  JOIN cap_cfg cfg;

-- --------------------------------------------------------------------
-- CAPD_CPU_HOURLY -- one row per (container, metric, END-hour bucket), the
-- HOUR-grain observation the HOUR_OF_WEEK anomaly baseline scores.
--   metric    = BUSY_PCT (host, OSSTAT: only under the CDB con_dbid) or
--               DB_CPU_PCT (per container, time model).
--   hour_ts   = the interval views' hour_ts, DB wall clock. With hourly AWR
--               one interval per bucket; with sparser snapshots (the
--               fixture: 12 h) only the buckets an interval ends in exist.
--   day_dt    = the interval views' day_dt (the day the interval ENDS on),
--               NOT TRUNC(hour_ts): a bucket labelled 00:00 that holds an
--               interval ending 23:58 belongs to the previous day, exactly as
--               CAPD_CPU_DAILY counts it.
--   value     = BUSY: 100 * SUM(busy_d) / SUM(busy_d + idle_d).
--               DB_CPU: 100 * DB CPU seconds / SUM(cap_sec), the hourly
--               version of CAPD_DBTIME_DAILY.db_cpu_pct (CPU ceiling).
--   gap_flag  = 'Y' when any interval in the bucket is_gap_hour: a long or
--               non-positive interval says nothing about this hour, so it is
--               neither scored nor used as a baseline.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capd_cpu_hourly AS
SELECT dbid,
       con_dbid,
       'BUSY_PCT'                                                AS metric,
       hour_ts,
       MIN(day_dt)                                               AS day_dt,
       100 * SUM(busy_d) / NULLIF(SUM(busy_d) + SUM(idle_d), 0)  AS value,
       COUNT(*)                                                  AS n_intervals,
       ROUND(MAX(ivl_hours), 2)                                  AS ivl_hours,
       CASE WHEN MAX(is_gap_hour) = 1 THEN 'Y' ELSE 'N' END      AS gap_flag
FROM   capd_cpu_interval
GROUP  BY dbid, con_dbid, hour_ts
UNION ALL
SELECT dbid,
       con_dbid,
       'DB_CPU_PCT',
       hour_ts,
       MIN(day_dt),
       100 * (SUM(CASE WHEN cap_sec IS NOT NULL THEN db_cpu_d END) / 1e6)
           / NULLIF(SUM(cap_sec), 0),
       COUNT(*),
       ROUND(MAX(ivl_hours), 2),
       CASE WHEN MAX(is_gap_hour) = 1 THEN 'Y' ELSE 'N' END
FROM   capd_dbtime_interval
GROUP  BY dbid, con_dbid, hour_ts;

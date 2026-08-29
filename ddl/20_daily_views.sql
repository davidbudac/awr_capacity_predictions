--
-- ddl/20_daily_views.sql -- CAPD_* daily series over the CAPV_* seam.
-- =====================================================================
-- Collapses AWR snapshots (irregular, per-instance, cumulative-counter) into
-- clean one-row-per-day series that the forecast/anomaly layers fit. All four
-- views are seam-agnostic: they touch only CAPV_*.
--
--   CAPD_TBSPC_DAILY  -- one row per (dbid, con_dbid, tablespace, day).
--                        Usage is a LEVEL, so we take the LAST sample of the
--                        day and convert blocks->bytes.
--   CAPD_TBSPC_DELTA  -- day-over-day used_bytes delta (negatives kept).
--   CAPD_CPU_DAILY    -- host busy% per day from OSSTAT counter deltas, with
--                        an instance-restart guard; average + p95/max/peak-
--                        window variants (M10.1).
--   CAPD_DBTIME_DAILY -- DB CPU / DB time / bg CPU seconds per day from
--                        SYS_TIME_MODEL counter deltas, same restart guard;
--                        DB CPU as % of core capacity + share of host (M10.2).
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
        SELECT dbid, con_dbid, tablespace_name, limit_bytes, exclude_flag
        FROM (
            SELECT t.dbid, t.con_dbid, t.tablespace_name,
                   o.limit_bytes, o.exclude_flag,
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
       l.n_samples
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
-- CAPD_CPU_DAILY -- host CPU busy% per day: average AND peak (M10.1).
-- BUSY_TIME / IDLE_TIME are cumulative centisecond counters; we difference
-- consecutive snaps per (dbid,con_dbid,instance) and DROP any interval that
-- (a) spans an instance restart (startup_time changed) or (b) shows a
-- negative delta (counter reset) -- both would corrupt the ratio. The
-- centisecond units cancel in every ratio, so no unit conversion is needed.
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
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capd_cpu_daily AS
WITH cfg AS (
        SELECT MAX(CASE WHEN cfg_name = 'peak_hour_from' THEN cfg_value END) AS peak_from,
               MAX(CASE WHEN cfg_name = 'peak_hour_to'   THEN cfg_value END) AS peak_to
        FROM   cap_config
     ),
     pivoted AS (
        SELECT o.dbid, o.con_dbid, o.instance_number, o.snap_id,
               MAX(CASE WHEN o.stat_name = 'BUSY_TIME'     THEN o.value END) AS busy_time,
               MAX(CASE WHEN o.stat_name = 'IDLE_TIME'     THEN o.value END) AS idle_time,
               MAX(CASE WHEN o.stat_name = 'IOWAIT_TIME'   THEN o.value END) AS iowait_time,
               MAX(CASE WHEN o.stat_name = 'NUM_CPUS'      THEN o.value END) AS num_cpus,
               MAX(CASE WHEN o.stat_name = 'NUM_CPU_CORES' THEN o.value END) AS num_cpu_cores
        FROM   capv_osstat o
        GROUP  BY o.dbid, o.con_dbid, o.instance_number, o.snap_id
     ),
     with_snap AS (
        SELECT p.*, s.end_interval_time, s.startup_time
        FROM   pivoted p
        JOIN   capv_snapshot s
          ON   s.dbid = p.dbid AND s.snap_id = p.snap_id
         AND   s.instance_number = p.instance_number
     ),
     deltas AS (
        SELECT w.*,
               w.busy_time - LAG(w.busy_time)
                 OVER (PARTITION BY w.dbid, w.con_dbid, w.instance_number ORDER BY w.snap_id) AS busy_d,
               w.idle_time - LAG(w.idle_time)
                 OVER (PARTITION BY w.dbid, w.con_dbid, w.instance_number ORDER BY w.snap_id) AS idle_d,
               LAG(w.startup_time)
                 OVER (PARTITION BY w.dbid, w.con_dbid, w.instance_number ORDER BY w.snap_id) AS prev_startup
        FROM   with_snap w
     ),
     valid AS (
        SELECT d.dbid, d.con_dbid, d.instance_number,
               TRUNC(d.end_interval_time) AS day_dt,
               d.busy_d, d.idle_d, d.num_cpus, d.num_cpu_cores,
               100 * d.busy_d / NULLIF(d.busy_d + d.idle_d, 0) AS ivl_busy_pct,
               -- peak-window membership: end hour in (peak_from, peak_to]
               CASE WHEN EXTRACT(HOUR FROM CAST(d.end_interval_time AS TIMESTAMP)) >  cfg.peak_from
                     AND EXTRACT(HOUR FROM CAST(d.end_interval_time AS TIMESTAMP)) <= cfg.peak_to
                    THEN 1 ELSE 0 END AS in_peak
        FROM   deltas d CROSS JOIN cfg
        WHERE  d.busy_d IS NOT NULL AND d.idle_d IS NOT NULL    -- drop first snap of each partition
          AND  d.busy_d >= 0 AND d.idle_d >= 0                  -- drop counter resets
          AND  d.startup_time = d.prev_startup                  -- drop restart-spanning intervals
     )
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
       COUNT(*)                                                      AS n_intervals
FROM   valid
GROUP  BY dbid, con_dbid, day_dt;

-- --------------------------------------------------------------------
-- CAPD_DBTIME_DAILY -- DB CPU / DB time / background CPU seconds per day,
-- plus DB CPU as a PERCENT OF CORE CAPACITY (M10.2) and the container's
-- share of host CPU.
-- SYS_TIME_MODEL values are cumulative MICROSECOND counters; same
-- diff-and-restart-guard pattern as CAPD_CPU_DAILY, summed across instances
-- per day and divided by 1e6 to seconds. db_cpu_per_core divides DB CPU by
-- the host core count (summed across instances, from OSSTAT NUM_CPU_CORES,
-- falling back to NUM_CPUS) so it is comparable across differently-sized hosts.
--   db_cpu_pct      = 100 * db_cpu_sec / (total_cores * 86400): the fraction
--                     of the host's core-seconds this container's foreground
--                     DB CPU consumed that day. Same scale as busy%, so it
--                     gets the same REGR fit + days_to_sat in CAPF_CPU_TREND.
--   db_cpu_p95_pct / db_cpu_max_pct / db_cpu_peak_pct
--                   = the per-INTERVAL version of db_cpu_pct (DB CPU seconds
--                     over the interval's elapsed core-seconds), then p95 /
--                     max over the day / time-weighted over the peak window
--                     (same (peak_hour_from, peak_hour_to] rule as
--                     CAPD_CPU_DAILY). Per-PDB "busy hour".
--   host_share_pct  = 100 * db_cpu_sec / host busy seconds that day (host
--                     busy from CAPD_CPU_DAILY summed over the dbid, since
--                     OSSTAT records under the CDB's con_dbid): how much of
--                     what the host was doing was THIS container.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capd_dbtime_daily AS
WITH cfg AS (
        SELECT MAX(CASE WHEN cfg_name = 'peak_hour_from' THEN cfg_value END) AS peak_from,
               MAX(CASE WHEN cfg_name = 'peak_hour_to'   THEN cfg_value END) AS peak_to
        FROM   cap_config
     ),
     pivoted AS (
        SELECT m.dbid, m.con_dbid, m.instance_number, m.snap_id,
               MAX(CASE WHEN m.stat_name = 'DB CPU'             THEN m.value END) AS db_cpu,
               MAX(CASE WHEN m.stat_name = 'DB time'            THEN m.value END) AS db_time,
               MAX(CASE WHEN m.stat_name = 'background cpu time' THEN m.value END) AS bg_cpu
        FROM   capv_time_model m
        GROUP  BY m.dbid, m.con_dbid, m.instance_number, m.snap_id
     ),
     with_snap AS (
        SELECT p.*, s.end_interval_time, s.startup_time
        FROM   pivoted p
        JOIN   capv_snapshot s
          ON   s.dbid = p.dbid AND s.snap_id = p.snap_id
         AND   s.instance_number = p.instance_number
     ),
     deltas AS (
        SELECT w.*,
               w.db_cpu  - LAG(w.db_cpu)
                 OVER (PARTITION BY w.dbid, w.con_dbid, w.instance_number ORDER BY w.snap_id) AS db_cpu_d,
               w.db_time - LAG(w.db_time)
                 OVER (PARTITION BY w.dbid, w.con_dbid, w.instance_number ORDER BY w.snap_id) AS db_time_d,
               w.bg_cpu  - LAG(w.bg_cpu)
                 OVER (PARTITION BY w.dbid, w.con_dbid, w.instance_number ORDER BY w.snap_id) AS bg_cpu_d,
               LAG(w.startup_time)
                 OVER (PARTITION BY w.dbid, w.con_dbid, w.instance_number ORDER BY w.snap_id) AS prev_startup,
               -- interval length in seconds (DATE arithmetic on the TIMESTAMPs)
               ( CAST(w.end_interval_time AS DATE)
                 - CAST(LAG(w.end_interval_time)
                          OVER (PARTITION BY w.dbid, w.con_dbid, w.instance_number ORDER BY w.snap_id) AS DATE)
               ) * 86400 AS elapsed_sec
        FROM   with_snap w
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
     valid AS (
        SELECT d.dbid, d.con_dbid,
               TRUNC(d.end_interval_time) AS day_dt,
               d.db_cpu_d, d.db_time_d, d.bg_cpu_d, d.elapsed_sec,
               c.total_cores,
               CASE WHEN c.total_cores > 0 AND d.elapsed_sec > 0
                    THEN 100 * (d.db_cpu_d / 1e6) / (c.total_cores * d.elapsed_sec)
               END AS ivl_cpu_pct,
               CASE WHEN EXTRACT(HOUR FROM CAST(d.end_interval_time AS TIMESTAMP)) >  cfg.peak_from
                     AND EXTRACT(HOUR FROM CAST(d.end_interval_time AS TIMESTAMP)) <= cfg.peak_to
                    THEN 1 ELSE 0 END AS in_peak
        FROM   deltas d
        CROSS  JOIN cfg
        LEFT   JOIN cores c ON c.dbid = d.dbid
        WHERE  d.db_cpu_d IS NOT NULL AND d.db_time_d IS NOT NULL
          AND  d.db_cpu_d >= 0 AND d.db_time_d >= 0 AND NVL(d.bg_cpu_d,0) >= 0
          AND  d.startup_time = d.prev_startup
     ),
     host AS (
        SELECT dbid, day_dt, SUM(host_busy_sec) AS host_busy_sec
        FROM   capd_cpu_daily
        GROUP  BY dbid, day_dt
     )
SELECT v.dbid,
       v.con_dbid,
       v.day_dt,
       SUM(v.db_cpu_d)  / 1e6                              AS db_cpu_sec,
       SUM(v.db_time_d) / 1e6                              AS db_time_sec,
       SUM(v.bg_cpu_d)  / 1e6                              AS bg_cpu_sec,
       CASE WHEN v.total_cores > 0
            THEN (SUM(v.db_cpu_d) / 1e6) / v.total_cores
       END                                                 AS db_cpu_per_core,
       CASE WHEN v.total_cores > 0
            THEN 100 * (SUM(v.db_cpu_d) / 1e6) / (v.total_cores * 86400)
       END                                                 AS db_cpu_pct,
       PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY v.ivl_cpu_pct) AS db_cpu_p95_pct,
       MAX(v.ivl_cpu_pct)                                  AS db_cpu_max_pct,
       CASE WHEN v.total_cores > 0
            THEN 100 * (SUM(CASE WHEN v.in_peak = 1 THEN v.db_cpu_d END) / 1e6)
                 / NULLIF(v.total_cores * SUM(CASE WHEN v.in_peak = 1 THEN v.elapsed_sec END), 0)
       END                                                 AS db_cpu_peak_pct,
       SUM(v.in_peak)                                      AS peak_intervals,
       CASE WHEN h.host_busy_sec > 0
            THEN 100 * (SUM(v.db_cpu_d) / 1e6) / h.host_busy_sec
       END                                                 AS host_share_pct,
       v.total_cores,
       COUNT(*)                                            AS n_intervals
FROM   valid v
LEFT   JOIN host h ON h.dbid = v.dbid AND h.day_dt = v.day_dt
GROUP  BY v.dbid, v.con_dbid, v.day_dt, v.total_cores, h.host_busy_sec;

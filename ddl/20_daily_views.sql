--
-- ddl/20_daily_views.sql -- CAPD_* daily series over the CAPV_* seam.
-- =====================================================================
-- Collapses AWR snapshots (irregular, per-instance, cumulative-counter) into
-- clean one-row-per-day series that the forecast/anomaly layers fit. All five
-- views are seam-agnostic: they touch only CAPV_*.
--
--   CAPD_TBSPC_DAILY   -- one row per (dbid, con_dbid, tablespace, day).
--                         Usage is a LEVEL, so we take the LAST sample of the
--                         day and convert blocks->bytes.
--   CAPD_TBSPC_DELTA   -- day-over-day used_bytes delta (negatives kept).
--   CAPD_COUNTER_DELTA -- every cumulative counter differenced once per
--                         interval, with the instance-restart flag.
--   CAPD_CPU_DAILY     -- host busy% per day from the OSSTAT deltas; average +
--                         p95/max/peak-window variants (M10.1); AWR-gap
--                         columns (M10.5); day coverage (covered_sec /
--                         is_complete).
--   CAPD_DBTIME_DAILY  -- DB CPU / DB time / bg CPU seconds per day per
--                         container from the time-model deltas; DB CPU as % of
--                         logical-CPU capacity + share of host (M10.2); the
--                         same gap and coverage columns.
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
-- CAPD_CPU_DAILY, CAPD_DBTIME_DAILY and the REDO_GB_DAY branch of
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
-- CAPD_CPU_DAILY -- host CPU busy% per day: average AND peak (M10.1).
-- BUSY_TIME / IDLE_TIME are cumulative centisecond counters, differenced in
-- CAPD_COUNTER_DELTA. An interval is used only when both deltas exist and
-- neither is a restart (startup_time changed, or a negative delta): either
-- would corrupt the ratio. The centisecond units cancel in every ratio, so no
-- unit conversion is needed.
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
--   * CAPA_CPU_ANOM (ddl/40) drops gap_flag='Y' days from the same-weekday
--     baseline and never flags one, and CAPA_CPU_SHIFT skips them too.
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
WITH ivl AS (
        -- BUSY_TIME and IDLE_TIME side by side, one row per interval.
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
        SELECT i.dbid, i.con_dbid, i.instance_number,
               TRUNC(i.end_time) AS day_dt,
               i.busy_d, i.idle_d, l.num_cpus, l.num_cpu_cores,
               i.ivl_sec,
               i.ivl_sec / 3600 AS ivl_hours,
               CASE WHEN i.ivl_sec / 3600 > cfg.cpu_gap_hours THEN 1 ELSE 0 END AS is_long,
               -- M10.5: per-interval busy% is only meaningful for an interval
               -- of normal length; a gap-spanning one is NULLed so it drops out
               -- of PERCENTILE_CONT / MAX (both ignore NULLs) instead of
               -- diluting the day's peak.
               CASE WHEN i.ivl_sec / 3600 <= cfg.cpu_gap_hours
                    THEN 100 * i.busy_d / NULLIF(i.busy_d + i.idle_d, 0)
               END AS ivl_busy_pct,
               -- peak-window membership: end hour in (peak_hour_from, peak_hour_to],
               -- and (M10.5) not a gap-spanning interval
               CASE WHEN EXTRACT(HOUR FROM CAST(i.end_time AS TIMESTAMP)) >  cfg.peak_hour_from
                     AND EXTRACT(HOUR FROM CAST(i.end_time AS TIMESTAMP)) <= cfg.peak_hour_to
                     AND i.ivl_sec / 3600 <= cfg.cpu_gap_hours
                    THEN 1 ELSE 0 END AS in_peak
        FROM   ivl i
        CROSS  JOIN cap_cfg cfg
        LEFT   JOIN lvl l
          ON   l.dbid = i.dbid AND l.con_dbid = i.con_dbid
         AND   l.instance_number = i.instance_number AND l.snap_id = i.snap_id
        WHERE  i.busy_d IS NOT NULL AND i.idle_d IS NOT NULL
          AND  i.is_restart = 'N'
     ),
     agg AS (
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
        FROM   valid
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
-- CAPD_DBTIME_DAILY -- DB CPU / DB time / background CPU seconds per day per
-- container, DB CPU as a PERCENT OF LOGICAL-CPU CAPACITY (M10.2) and the
-- container's share of host CPU.
-- The time-model counters (cumulative MICROSECONDS) come from
-- CAPD_COUNTER_DELTA with the same restart rule as CAPD_CPU_DAILY, summed
-- across instances per day and divided by 1e6 to seconds.
--   db_cpu_pct      = 100 * db_cpu_sec / SUM over the day's valid intervals
--                     of (num_cpus * ivl_sec): the share of the host's
--                     logical-CPU seconds this container's foreground DB CPU
--                     used while the counters were recording.
--                     Why logical CPUs: Oracle accrues CPU time per logical
--                     CPU (a thread on an SMT host), OSSTAT BUSY_TIME /
--                     IDLE_TIME are summed over NUM_CPUS, and the AWR report's
--                     own %Total CPU divides by NUM_CPUS. Dividing by cores
--                     read 2x on 2-way SMT (4-8x on POWER / SPARC) and fired
--                     DBCPU_SAT at half load. Now db_cpu_pct = busy_pct *
--                     host_share_pct / 100, the same scale as host busy%.
--                     num_cpus is read per interval at its end snapshot
--                     (NUM_CPUS, else NUM_CPU_CORES), so a host resize does
--                     not rewrite history. OSSTAT is host level and recorded
--                     under the CDB's con_dbid, so it is matched on (dbid,
--                     instance, snap_id) and serves every container. A
--                     snapshot with no OSSTAT row uses the instance's last
--                     earlier value.
--                     The denominator is the covered time, not 86400, so a
--                     partial, restart or gap day reads its true average.
--   db_cpu_p95_pct / db_cpu_max_pct / db_cpu_peak_pct
--                   = the per-INTERVAL version of db_cpu_pct (DB CPU seconds
--                     over the interval's num_cpus * ivl_sec), then p95 / max
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
     valid AS (
        SELECT i.dbid, i.con_dbid, i.instance_number,
               TRUNC(i.end_time) AS day_dt,
               i.db_cpu_d, i.db_time_d, i.bg_cpu_d, i.ivl_sec,
               n.num_cpus, n.num_cpu_cores,
               -- logical-CPU seconds the interval offered, NULL when unknown
               CASE WHEN n.num_cpus > 0 AND i.ivl_sec > 0
                    THEN n.num_cpus * i.ivl_sec
               END AS cap_sec,
               c.total_cores,
               i.ivl_sec / 3600 AS ivl_hours,
               CASE WHEN i.ivl_sec / 3600 > cfg.cpu_gap_hours THEN 1 ELSE 0 END AS is_long,
               CASE WHEN n.num_cpus > 0 AND i.ivl_sec > 0
                     AND i.ivl_sec / 3600 <= cfg.cpu_gap_hours
                    THEN 100 * (i.db_cpu_d / 1e6) / (n.num_cpus * i.ivl_sec)
               END AS ivl_cpu_pct,
               CASE WHEN EXTRACT(HOUR FROM CAST(i.end_time AS TIMESTAMP)) >  cfg.peak_hour_from
                     AND EXTRACT(HOUR FROM CAST(i.end_time AS TIMESTAMP)) <= cfg.peak_hour_to
                     AND i.ivl_sec / 3600 <= cfg.cpu_gap_hours
                    THEN 1 ELSE 0 END AS in_peak
        FROM   ivl i
        CROSS  JOIN cap_cfg cfg
        LEFT   JOIN ncpu n
          ON   n.dbid = i.dbid AND n.instance_number = i.instance_number AND n.snap_id = i.snap_id
        LEFT   JOIN cores c ON c.dbid = i.dbid
        WHERE  i.db_cpu_d IS NOT NULL AND i.db_time_d IS NOT NULL
          AND  i.is_restart = 'N'
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
               SUM(num_cpu_cores) AS num_cpu_cores
        FROM ( SELECT dbid, con_dbid, day_dt, instance_number,
                      MAX(num_cpus)      AS num_cpus,
                      MAX(num_cpu_cores) AS num_cpu_cores
               FROM   valid
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
        FROM   valid v
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
            THEN 'Y' ELSE 'N' END                                  AS is_complete
FROM   agg a
JOIN   cpus_day c
  ON   c.dbid = a.dbid AND c.con_dbid = a.con_dbid AND c.day_dt = a.day_dt
CROSS  JOIN cap_cfg cfg;

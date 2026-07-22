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
--                        an instance-restart guard.
--   CAPD_DBTIME_DAILY -- DB CPU / DB time / bg CPU seconds per day from
--                        SYS_TIME_MODEL counter deltas, same restart guard.
--
-- 19c note: LAG uses an inline OVER (PARTITION BY ... ORDER BY ...) on every
-- call -- the standalone WINDOW clause is 21c+.
--
SET DEFINE OFF

-- --------------------------------------------------------------------
-- CAPD_TBSPC_DAILY
--   used_bytes  = last-of-day used blocks * block size
--   size_bytes  = last-of-day allocated blocks * block size
--   limit_bytes = maxsize*bs when autoextend on (maxsize>0), else size*bs
-- TBSPC_SPACE_USAGE carries no instance_number/timestamp, so we derive the
-- day by joining snap_id -> CAPV_SNAPSHOT (MIN end_interval_time across
-- instances for that snap). UNDO + TEMPORARY tablespaces are excluded
-- (their "usage" is transient and not a growth signal).
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
       CASE WHEN l.max_blocks > 0
            THEN l.max_blocks  * COALESCE(t.block_size, b.block_size)
            ELSE l.size_blocks * COALESCE(t.block_size, b.block_size)
       END                                                   AS limit_bytes,
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
WHERE  t.contents NOT IN ('UNDO','TEMPORARY')
  AND  COALESCE(t.block_size, b.block_size) IS NOT NULL;

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
-- CAPD_CPU_DAILY -- host CPU busy% per day.
-- BUSY_TIME / IDLE_TIME are cumulative centisecond counters; we difference
-- consecutive snaps per (dbid,con_dbid,instance) and DROP any interval that
-- (a) spans an instance restart (startup_time changed) or (b) shows a
-- negative delta (counter reset) -- both would corrupt the ratio. Then per
-- day: busy% = 100 * SUM(busy_d) / SUM(busy_d+idle_d). The centisecond units
-- cancel in the ratio, so no unit conversion is needed.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capd_cpu_daily AS
WITH pivoted AS (
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
        SELECT dbid, con_dbid, instance_number,
               TRUNC(end_interval_time) AS day_dt,
               busy_d, idle_d, num_cpus, num_cpu_cores
        FROM   deltas
        WHERE  busy_d IS NOT NULL AND idle_d IS NOT NULL      -- drop first snap of each partition
          AND  busy_d >= 0 AND idle_d >= 0                    -- drop counter resets
          AND  startup_time = prev_startup                    -- drop restart-spanning intervals
     )
SELECT dbid,
       con_dbid,
       day_dt,
       100 * SUM(busy_d) / NULLIF(SUM(busy_d) + SUM(idle_d), 0) AS busy_pct,
       ROUND(AVG(num_cpus))                                     AS num_cpus,
       ROUND(AVG(num_cpu_cores))                                AS num_cpu_cores,
       COUNT(*)                                                 AS n_intervals
FROM   valid
GROUP  BY dbid, con_dbid, day_dt;

-- --------------------------------------------------------------------
-- CAPD_DBTIME_DAILY -- DB CPU / DB time / background CPU seconds per day.
-- SYS_TIME_MODEL values are cumulative MICROSECOND counters; same
-- diff-and-restart-guard pattern as CAPD_CPU_DAILY, summed across instances
-- per day and divided by 1e6 to seconds. db_cpu_per_core divides DB CPU by
-- the host core count (summed across instances, from OSSTAT NUM_CPU_CORES,
-- falling back to NUM_CPUS) so it is comparable across differently-sized hosts.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capd_dbtime_daily AS
WITH pivoted AS (
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
                 OVER (PARTITION BY w.dbid, w.con_dbid, w.instance_number ORDER BY w.snap_id) AS prev_startup
        FROM   with_snap w
     ),
     valid AS (
        SELECT dbid, con_dbid,
               TRUNC(end_interval_time) AS day_dt,
               db_cpu_d, db_time_d, bg_cpu_d
        FROM   deltas
        WHERE  db_cpu_d IS NOT NULL AND db_time_d IS NOT NULL
          AND  db_cpu_d >= 0 AND db_time_d >= 0 AND NVL(bg_cpu_d,0) >= 0
          AND  startup_time = prev_startup
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
     )
SELECT v.dbid,
       v.con_dbid,
       v.day_dt,
       SUM(v.db_cpu_d)  / 1e6                              AS db_cpu_sec,
       SUM(v.db_time_d) / 1e6                              AS db_time_sec,
       SUM(v.bg_cpu_d)  / 1e6                              AS bg_cpu_sec,
       CASE WHEN c.total_cores > 0
            THEN (SUM(v.db_cpu_d) / 1e6) / c.total_cores
       END                                                 AS db_cpu_per_core,
       COUNT(*)                                            AS n_intervals
FROM   valid v
LEFT   JOIN cores c ON c.dbid = v.dbid
GROUP  BY v.dbid, v.con_dbid, v.day_dt, c.total_cores;

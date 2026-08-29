--
-- ddl/25_series_daily.sql -- CAPD_SERIES_DAILY: fixed-ceiling series (M11).
-- =====================================================================
-- Milestone M11 adds three more capacity series that share one property the
-- tablespace/CPU layers already exploit: each has (or can have) a HARD CEILING
-- the value is approaching. Rather than one view per series, they land in a
-- single GENERIC daily view keyed by a `series` name, so the forecast layer
-- (ddl/35_series_forecast.sql), the report and CAPR_ALERTS handle all of them
-- -- and any future one -- with no extra code:
--
--   PROCESSES    (M11.1) peak sessions/processes vs the instance's `processes`
--   SESSIONS     (M11.1) / `sessions` init parameter (CAPV_RESOURCE_LIMIT).
--                unit COUNT. limit = the parameter value.
--   REDO_GB_DAY  (M11.2) redo generated per day in GiB (CAPV_SYSSTAT
--                'redo size' counter deltas). unit GIB_PER_DAY. NO limit --
--                FRA / archive-destination sizing is an operator decision, so
--                the series is a trend, not a days-to-limit.
--   DB_SIZE_GB   (M11.3) total database size = SUM(used_bytes) over
--                CAPD_TBSPC_DAILY, with SUM(limit_bytes) as the ceiling.
--                unit GIB.
--
-- Column contract:
--   (dbid, con_dbid, series, day_dt, value, limit_value, unit, n_samples)
-- limit_value is NULL when the series has no ceiling (REDO_GB_DAY) or when it
-- could not be resolved (an UNLIMITED / non-numeric resource limit).
--
-- Seam-agnostic: only CAPV_* (+ CAPD_TBSPC_DAILY, itself seam-agnostic).
-- 19c note: every LAG carries an inline OVER (PARTITION BY ... ORDER BY ...).
--
-- Facts worth knowing before changing this file:
--   * DBA_HIST_RESOURCE_LIMIT.MAX_UTILIZATION is a HIGH-WATER MARK since
--     instance startup, so within one startup epoch it is monotonically
--     non-decreasing and the daily MAX is simply the day's end-of-day HWM.
--     That is exactly the number a DBA compares against `processes` -- but it
--     means an instance restart RESETS the series, which shows up as a step
--     down (and, like any level shift, degrades R^2 rather than lying).
--   * RAC: limits are PER INSTANCE, so both the utilization and the limit are
--     SUMMED across instances -- the fleet-wide ceiling is the sum of the
--     instance ceilings. If ANY instance's limit is non-numeric (UNLIMITED)
--     the day's limit_value is NULL rather than an understated sum.
--   * DB_SIZE_GB inherits CAPD_TBSPC_DAILY's rules: UNDO and TEMPORARY
--     tablespaces are EXCLUDED (their usage is transient, not growth), and
--     CAP_TBSPC_OVERRIDE limits / exclusions (M9.5) are already applied. So
--     "total DB size" here means permanent-tablespace bytes actually used.
--   * Redo is one stream per DATABASE, and AWR records SYSSTAT under the CDB's
--     con_dbid (same as OSSTAT), so REDO_GB_DAY is a CDB-level series.
--
SET DEFINE OFF

CREATE OR REPLACE VIEW capd_series_daily AS
WITH snap AS (
        -- CAPV_SNAPSHOT sets con_dbid := dbid (the source has no CON_DBID), so
        -- every join below is on (dbid, snap_id, instance_number) and the real
        -- con_dbid comes from the fact view -- the same rule CAPD_CPU_DAILY uses.
        SELECT dbid, instance_number, snap_id, end_interval_time, startup_time
        FROM   capv_snapshot
     ),
     -- ---------------- PROCESSES / SESSIONS (M11.1) ----------------
     rl AS (
        SELECT r.dbid, r.con_dbid, r.instance_number,
               TRUNC(s.end_interval_time)  AS day_dt,
               UPPER(r.resource_name)      AS series,
               r.max_utilization           AS util,
               r.limit_value               AS lim
        FROM   capv_resource_limit r
        JOIN   snap s
          ON   s.dbid = r.dbid AND s.snap_id = r.snap_id
         AND   s.instance_number = r.instance_number
        WHERE  r.max_utilization IS NOT NULL
     ),
     -- Per instance first (the limit is per instance), then summed.
     rl_inst AS (
        SELECT dbid, con_dbid, series, day_dt, instance_number,
               MAX(util) AS util,
               MAX(lim)  AS lim,
               COUNT(*)  AS n_samples
        FROM   rl
        GROUP  BY dbid, con_dbid, series, day_dt, instance_number
     ),
     rl_day AS (
        SELECT dbid, con_dbid, series, day_dt,
               SUM(util)      AS val,
               -- NULL (not an understated sum) if any instance is UNLIMITED.
               CASE WHEN COUNT(*) = COUNT(lim) THEN SUM(lim) END AS lim,
               SUM(n_samples) AS n_samples
        FROM   rl_inst
        GROUP  BY dbid, con_dbid, series, day_dt
     ),
     -- ---------------- REDO_GB_DAY (M11.2) ----------------
     -- 'redo size' is a cumulative BYTE counter; same diff-and-restart-guard
     -- pattern as CAPD_CPU_DAILY: difference consecutive snaps per
     -- (dbid, con_dbid, instance) and drop any interval that spans a restart
     -- or shows a negative delta (counter reset). The delta is attributed to
     -- the day the interval ENDS on, as everywhere else in the suite.
     redo_raw AS (
        SELECT x.dbid, x.con_dbid, x.instance_number, x.snap_id, x.value,
               s.end_interval_time, s.startup_time
        FROM   capv_sysstat x
        JOIN   snap s
          ON   s.dbid = x.dbid AND s.snap_id = x.snap_id
         AND   s.instance_number = x.instance_number
        WHERE  x.stat_name = 'redo size'
     ),
     redo_delta AS (
        SELECT r.dbid, r.con_dbid,
               TRUNC(r.end_interval_time) AS day_dt,
               r.startup_time,
               r.value - LAG(r.value)
                 OVER (PARTITION BY r.dbid, r.con_dbid, r.instance_number
                       ORDER BY r.snap_id)         AS d_bytes,
               LAG(r.startup_time)
                 OVER (PARTITION BY r.dbid, r.con_dbid, r.instance_number
                       ORDER BY r.snap_id)         AS prev_startup
        FROM   redo_raw r
     ),
     redo_day AS (
        SELECT dbid, con_dbid,
               'REDO_GB_DAY'            AS series,
               day_dt,
               SUM(d_bytes) / 1073741824 AS val,
               CAST(NULL AS NUMBER)      AS lim,
               COUNT(*)                  AS n_samples
        FROM   redo_delta
        WHERE  d_bytes IS NOT NULL          -- first snap of each partition
          AND  d_bytes >= 0                 -- counter reset
          AND  startup_time = prev_startup  -- restart-spanning interval
        GROUP  BY dbid, con_dbid, day_dt
     ),
     -- ---------------- DB_SIZE_GB (M11.3) ----------------
     -- One number per container per day: the sum of every permanent
     -- tablespace's last-of-day used bytes, against the sum of their ceilings.
     -- Excluded tablespaces (M9.5) and UNDO/TEMPORARY are already gone at this
     -- point, so nothing needs re-filtering here.
     size_day AS (
        SELECT dbid, con_dbid,
               'DB_SIZE_GB'                  AS series,
               day_dt,
               SUM(used_bytes)  / 1073741824 AS val,
               SUM(limit_bytes) / 1073741824 AS lim,
               COUNT(*)                      AS n_samples   -- tablespaces summed
        FROM   capd_tbspc_daily
        GROUP  BY dbid, con_dbid, day_dt
     )
SELECT dbid, con_dbid, series, day_dt, val AS value, lim AS limit_value,
       'COUNT'       AS unit, n_samples
FROM   rl_day
UNION ALL
SELECT dbid, con_dbid, series, day_dt, val, lim,
       'GIB_PER_DAY' AS unit, n_samples
FROM   redo_day
UNION ALL
SELECT dbid, con_dbid, series, day_dt, val, lim,
       'GIB'         AS unit, n_samples
FROM   size_day;

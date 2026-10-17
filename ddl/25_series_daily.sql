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
--   (dbid, con_dbid, series, day_dt, value, limit_value, unit, n_samples,
--    covered_sec, is_complete, day_gap, max_interval_hours, gap_flag)
-- limit_value is NULL when the series has no ceiling (REDO_GB_DAY) or when it
-- could not be resolved (an UNLIMITED / non-numeric resource limit).
-- covered_sec / is_complete mean what they mean in CAPD_CPU_DAILY, and only a
-- flow series has them: REDO_GB_DAY sums counter deltas, so a day with half
-- its intervals reads half the redo. The level series (PROCESSES, SESSIONS,
-- DB_SIZE_GB) read one sample per day, so they carry covered_sec NULL and
-- is_complete 'Y'.
-- M15 gap columns, read by the anomaly layer (a gap day is neither scored
-- nor used as baseline):
--   day_gap            = days since the series' previous row.
--   max_interval_hours = REDO_GB_DAY: the longest counter interval ending
--                        that day; NULL for the level series.
--   gap_flag           = 'Y' for REDO_GB_DAY when max_interval_hours >
--                        cpu_gap_hours (the day carries more than a day of
--                        redo); for DB_SIZE_GB when n_samples differs from the
--                        previous row's (the tablespace SET changed, so the
--                        day-over-day move measures membership, not growth);
--                        else 'N'.
--
-- Seam-agnostic: only CAPV_* (+ CAPD_TBSPC_DAILY and CAPD_COUNTER_DELTA,
-- both seam-agnostic).
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
--   * REDO_GB_DAY is per container in local mode (CAPV_SYSSTAT reads
--     DBA_HIST_CON_SYSSTAT). The log stream is shared, so the CDB's redo is
--     the SUM over its containers. Warehouse mode still has one CDB-level row.
--   * PROCESSES / SESSIONS are CDB-wide: DBA_HIST_RESOURCE_LIMIT is root-only
--     in CDB$ROOT.
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
     -- 'redo size' is a cumulative BYTE counter, differenced once in
     -- CAPD_COUNTER_DELTA with the same restart rule as the CPU views.
     -- covered_sec is per instance, as in CAPD_CPU_DAILY.
     -- day_dt is projected in an inline view and grouped as a column: a
     -- GROUP BY TRUNC(end_time) here raised ORA-00979 on 19c once
     -- CAPR_FORECAST_POINTS merged it with the CPU views over the same
     -- CAPD_COUNTER_DELTA.
     redo_day AS (
        SELECT dbid, con_dbid,
               'REDO_GB_DAY'                                  AS series,
               day_dt,
               SUM(delta) / 1073741824                        AS val,
               CAST(NULL AS NUMBER)                           AS lim,
               COUNT(*)                                       AS n_samples,
               SUM(ivl_sec) / COUNT(DISTINCT instance_number) AS covered_sec,
               MAX(ivl_sec) / 3600                            AS max_ivl
        FROM  ( SELECT dbid, con_dbid, instance_number,
                       TRUNC(end_time) AS day_dt, delta, ivl_sec
                FROM   capd_counter_delta
                WHERE  source = 'SYSSTAT'
                  AND  stat_name = 'redo size'
                  AND  delta IS NOT NULL
                  AND  is_restart = 'N' )
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
     ),
     u AS (
        SELECT dbid, con_dbid, series, day_dt, val, lim,
               'COUNT'       AS unit, n_samples,
               CAST(NULL AS NUMBER) AS covered_sec, 'Y' AS is_complete,
               CAST(NULL AS NUMBER) AS max_ivl
        FROM   rl_day
        UNION ALL
        SELECT r.dbid, r.con_dbid, r.series, r.day_dt, r.val, r.lim,
               'GIB_PER_DAY' AS unit, r.n_samples,
               r.covered_sec,
               CASE WHEN r.covered_sec >= cfg.complete_day_pct / 100 * 86400
                    THEN 'Y' ELSE 'N' END,
               r.max_ivl
        FROM   redo_day r
        CROSS  JOIN cap_cfg cfg
        UNION ALL
        SELECT dbid, con_dbid, series, day_dt, val, lim,
               'GIB'         AS unit, n_samples,
               CAST(NULL AS NUMBER), 'Y', CAST(NULL AS NUMBER)
        FROM   size_day
     )
SELECT u.dbid, u.con_dbid, u.series, u.day_dt, u.val AS value, u.lim AS limit_value,
       u.unit, u.n_samples, u.covered_sec, u.is_complete,
       u.day_dt - LAG(u.day_dt) OVER (PARTITION BY u.dbid, u.con_dbid, u.series
                                      ORDER BY u.day_dt)                      AS day_gap,
       ROUND(u.max_ivl, 2)                                                    AS max_interval_hours,
       CASE
           WHEN u.max_ivl > cfg.cpu_gap_hours THEN 'Y'
           WHEN u.series = 'DB_SIZE_GB'
            AND u.n_samples <> LAG(u.n_samples) OVER (PARTITION BY u.dbid, u.con_dbid, u.series
                                                      ORDER BY u.day_dt) THEN 'Y'
           ELSE 'N'
       END                                                                    AS gap_flag
FROM   u CROSS JOIN cap_cfg cfg;

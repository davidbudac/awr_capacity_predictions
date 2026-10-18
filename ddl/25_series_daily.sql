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
--   ASM_DG:+<name>  used space of one ASM diskgroup (CAPV_ASM_DISKGROUP),
--                (total_mb - free_mb) / 1024 at the day's LAST sample,
--                against total_mb / 1024. unit GIB. Raw MB before
--                mirroring, so the percent is right for any redundancy and
--                the GiB are raw. Autoextend maxsize is often fiction (every
--                autoextend smallfile datafile reports 32 GiB), and the
--                diskgroup is the real ceiling under it. The '+' is added
--                here because AWR stores the name without it.
--   TEMP_PEAK:<tablespace>  the day's PEAK used space of a TEMPORARY or
--   UNDO_PEAK:<tablespace>  UNDO tablespace: MAX(used blocks) over the day's
--                samples * block size, in GiB, against the day's MAX of
--                (maxsize when autoextend, else allocated size). unit GIB.
--                CAPD_TBSPC_DAILY leaves these tablespaces out because their
--                level is not growth, but running out of them is an outage
--                (ORA-01652 / ORA-30036), so here they are read as peaks.
--                A peak is the highest SAMPLED value: usage between two
--                snapshots is not seen. CAP_TBSPC_OVERRIDE does not apply.
--
-- Column contract:
--   (dbid, con_dbid, series, day_dt, value, limit_value, unit, n_samples,
--    covered_sec, is_complete, day_gap, max_interval_hours, gap_flag,
--    worst_inst_pct, worst_inst)
-- limit_value is NULL when the series has no ceiling (REDO_GB_DAY) or when it
-- could not be resolved (an UNLIMITED / non-numeric resource limit).
-- covered_sec / is_complete mean what they mean in CAPD_CPU_DAILY, and only a
-- flow series has them: REDO_GB_DAY sums counter deltas, so a day with half
-- its intervals reads half the redo. The level series (PROCESSES, SESSIONS,
-- DB_SIZE_GB, ASM_DG, TEMP_PEAK, UNDO_PEAK) read samples of a level, so they
-- carry covered_sec NULL and is_complete 'Y'.
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
--                        else 'N'. ASM_DG / TEMP_PEAK / UNDO_PEAK count
--                        samples, not members, so they read 'N'.
--
-- worst_inst_pct / worst_inst (RAC) are filled on PROCESSES / SESSIONS only,
-- NULL on every other series: the day's highest per-instance
-- 100 * max_utilization / limit, and the instance_number that had it (the
-- highest number on a tie). The series value / limit_value stay the summed
-- fleet figures, so a node at 990 of 1000 beside one at 10 of 1000 reads 50%
-- there and 99% here; SERIES_NEARLIMIT judges the larger (ddl/45
-- CAPR_SEVERITY). On a single instance worst_inst_pct is the plain
-- percent of limit and worst_inst is that instance. NULL when no instance
-- has a numeric limit.
--
-- Seam-agnostic: only CAPV_* (+ CAPD_TBSPC_DAILY and CAPD_COUNTER_DELTA,
-- both seam-agnostic). The ASM_DG and TEMP/UNDO branches give each series a
-- name of its own, so CAPF_SERIES_FORECAST, the SERIES_LIMIT /
-- SERIES_NEARLIMIT alerts, report section 7 and the point feeds cover them
-- with no code of their own.
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
--     the day's limit_value is NULL rather than an understated sum. The
--     sum hides one exhausted node, so the day also carries the WORST
--     instance (worst_inst_pct / worst_inst, above) for the near-limit
--     alert; the series itself stays one fleet row (no instance_number
--     anywhere downstream).
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
               COUNT(*)  AS n_samples,
               100 * MAX(util) / NULLIF(MAX(lim), 0) AS pct
        FROM   rl
        GROUP  BY dbid, con_dbid, series, day_dt, instance_number
     ),
     rl_day AS (
        SELECT dbid, con_dbid, series, day_dt,
               SUM(util)      AS val,
               -- NULL (not an understated sum) if any instance is UNLIMITED.
               CASE WHEN COUNT(*) = COUNT(lim) THEN SUM(lim) END AS lim,
               SUM(n_samples) AS n_samples,
               -- Worst node: its percent of its OWN limit, and which node.
               -- NULLS FIRST so DENSE_RANK LAST lands on the largest number.
               MAX(pct)       AS worst_pct,
               CASE WHEN MAX(pct) IS NOT NULL
                    THEN MAX(instance_number) KEEP (DENSE_RANK LAST ORDER BY pct NULLS FIRST)
               END            AS worst_inst
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
     -- Space usage has no instance_number: the day comes from the snapshot's
     -- earliest end time across instances, as in CAPD_TBSPC_DAILY.
     snap_time AS (
        SELECT dbid, snap_id, MIN(end_interval_time) AS eit
        FROM   capv_snapshot
        GROUP  BY dbid, snap_id
     ),
     -- ---------------- ASM_DG ----------------
     -- A level: the day's last sample. A dismounted group reads total_mb 0
     -- and is skipped.
     -- day_dt is projected in the inline view and grouped as a column, for
     -- the ORA-00979 reason given at redo_day.
     asm_day AS (
        SELECT dbid, con_dbid, series, day_dt,
               MAX(used_mb)  KEEP (DENSE_RANK LAST ORDER BY eit) / 1024 AS val,
               MAX(total_mb) KEEP (DENSE_RANK LAST ORDER BY eit) / 1024 AS lim,
               COUNT(*)                                                AS n_samples
        FROM  ( SELECT a.dbid, a.con_dbid,
                       'ASM_DG:+' || a.group_name AS series,
                       TRUNC(st.eit)              AS day_dt,
                       st.eit,
                       a.total_mb - a.free_mb     AS used_mb,
                       a.total_mb
                FROM   capv_asm_diskgroup a
                JOIN   snap_time st
                  ON   st.dbid = a.dbid AND st.snap_id = a.snap_id
                WHERE  a.total_mb > 0
                  AND  a.free_mb IS NOT NULL )
        GROUP  BY dbid, con_dbid, series, day_dt
     ),
     -- ---------------- TEMP_PEAK / UNDO_PEAK ----------------
     -- Read straight off the seam: CAPD_TBSPC_DAILY drops these contents.
     -- Block size as in CAPD_TBSPC_DAILY (tablespace dim first, datafile
     -- fallback: DBA_HIST_DATAFILE has no tempfiles anyway).
     tu AS (
        SELECT u.dbid, u.con_dbid,
               CASE t.contents WHEN 'TEMPORARY' THEN 'TEMP_PEAK:' ELSE 'UNDO_PEAK:' END
                 || t.tablespace_name                                         AS series,
               TRUNC(st.eit)                                                  AS day_dt,
               u.tablespace_usedsize * COALESCE(t.block_size, b.block_size)   AS used_bytes,
               CASE WHEN u.tablespace_maxsize > 0 THEN u.tablespace_maxsize
                    ELSE u.tablespace_size END
                 * COALESCE(t.block_size, b.block_size)                       AS limit_bytes
        FROM   capv_tbspc_usage u
        JOIN   snap_time st
          ON   st.dbid = u.dbid AND st.snap_id = u.snap_id
        JOIN   capv_tablespace t
          ON   t.dbid = u.dbid AND t.con_dbid = u.con_dbid AND t.tablespace_id = u.tablespace_id
        LEFT   JOIN (SELECT dbid, con_dbid, tablespace_id, MAX(block_size) AS block_size
                     FROM   capv_datafile
                     GROUP  BY dbid, con_dbid, tablespace_id) b
          ON   b.dbid = u.dbid AND b.con_dbid = u.con_dbid AND b.tablespace_id = u.tablespace_id
        WHERE  t.contents IN ('TEMPORARY','UNDO')
     ),
     tu_day AS (
        SELECT dbid, con_dbid, series, day_dt,
               MAX(used_bytes)  / 1073741824 AS val,
               MAX(limit_bytes) / 1073741824 AS lim,
               COUNT(*)                      AS n_samples
        FROM   tu
        WHERE  used_bytes IS NOT NULL
        GROUP  BY dbid, con_dbid, series, day_dt
     ),
     u AS (
        SELECT dbid, con_dbid, series, day_dt, val, lim,
               'COUNT'       AS unit, n_samples,
               CAST(NULL AS NUMBER) AS covered_sec, 'Y' AS is_complete,
               CAST(NULL AS NUMBER) AS max_ivl,
               worst_pct, worst_inst
        FROM   rl_day
        UNION ALL
        SELECT r.dbid, r.con_dbid, r.series, r.day_dt, r.val, r.lim,
               'GIB_PER_DAY' AS unit, r.n_samples,
               r.covered_sec,
               CASE WHEN r.covered_sec >= cfg.complete_day_pct / 100 * 86400
                    THEN 'Y' ELSE 'N' END,
               r.max_ivl,
               CAST(NULL AS NUMBER), CAST(NULL AS NUMBER)
        FROM   redo_day r
        CROSS  JOIN cap_cfg cfg
        UNION ALL
        SELECT dbid, con_dbid, series, day_dt, val, lim,
               'GIB'         AS unit, n_samples,
               CAST(NULL AS NUMBER), 'Y', CAST(NULL AS NUMBER),
               CAST(NULL AS NUMBER), CAST(NULL AS NUMBER)
        FROM   size_day
        UNION ALL
        SELECT dbid, con_dbid, series, day_dt, val, lim,
               'GIB', n_samples, CAST(NULL AS NUMBER), 'Y', CAST(NULL AS NUMBER),
               CAST(NULL AS NUMBER), CAST(NULL AS NUMBER)
        FROM   asm_day
        UNION ALL
        SELECT dbid, con_dbid, series, day_dt, val, lim,
               'GIB', n_samples, CAST(NULL AS NUMBER), 'Y', CAST(NULL AS NUMBER),
               CAST(NULL AS NUMBER), CAST(NULL AS NUMBER)
        FROM   tu_day
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
       END                                                                    AS gap_flag,
       u.worst_pct                                                            AS worst_inst_pct,
       u.worst_inst
FROM   u CROSS JOIN cap_cfg cfg;

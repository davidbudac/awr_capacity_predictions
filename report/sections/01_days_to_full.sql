--
-- 01_days_to_full.sql -- tablespaces ranked by days-to-full + near-full-now.
-- Consumes CAPF_TBSPC_FORECAST (+ CAPR_CONTAINER for DB/PDB labels).
-- WARN/CRIT from CAP_CONFIG (&dtf_warn/&dtf_crit, &nf_warn/&nf_crit).
--
-- M7.1: the ranking no longer hides non-OK fits -- every computable
-- days_to_full appears WITH its quality marker (a LOW_CONFIDENCE estimate is
-- still a signal; the marker tells you how hard to trust it), and a second
-- "near-full now" ranking by PCT_USED is independent of fit quality entirely,
-- so a 97%-full tablespace with INSUFFICIENT_HISTORY can never vanish.
--
PROMPT
PROMPT == 1a. TABLESPACES BY DAYS-TO-FULL (any quality; top &top_n) ==
PROMPT     SEV: CRIT<=&dtf_crit days, WARN<=&dtf_warn days. ACCEL>1.5 = growth accelerating.
PROMPT     Trust the estimate per QUALITY (only OK is reliable).

COLUMN db_pdb          FORMAT A20           HEADING 'DB/PDB'
COLUMN tablespace_name FORMAT A18           HEADING 'TABLESPACE'
COLUMN pct_used        FORMAT 990.0         HEADING 'PCT_USED'
COLUMN cur_gb          FORMAT 99990.00      HEADING 'CUR_GB'
COLUMN limit_gb        FORMAT 99990.00      HEADING 'LIMIT_GB'
COLUMN slope_mb        FORMAT 999990.000    HEADING 'MB/DAY'
COLUMN days_to_full    FORMAT 99999990      HEADING 'DAYS_FULL'
COLUMN sev             FORMAT A4            HEADING 'SEV'
COLUMN quality         FORMAT A20           HEADING 'QUALITY'
COLUMN accel           FORMAT 990.00        HEADING 'ACCEL'

SELECT NVL(c.db_pdb, TO_CHAR(f.con_dbid)) AS db_pdb,
       f.tablespace_name,
       f.pct_used,
       f.cur_used    / 1024 / 1024 / 1024 AS cur_gb,
       f.limit_bytes / 1024 / 1024 / 1024 AS limit_gb,
       f.slope_bpd   / 1024 / 1024        AS slope_mb,
       f.days_to_full,
       CASE WHEN f.days_to_full <= &dtf_crit THEN 'CRIT'
            WHEN f.days_to_full <= &dtf_warn THEN 'WARN'
            ELSE 'ok'  END                AS sev,
       f.quality,
       f.accel_ratio                      AS accel
FROM   capf_tbspc_forecast f
LEFT   JOIN capr_container c
  ON   c.dbid = f.dbid AND c.con_dbid = f.con_dbid
WHERE  f.days_to_full IS NOT NULL
ORDER  BY f.days_to_full
FETCH FIRST &top_n ROWS ONLY;

PROMPT
PROMPT == 1b. NEAR-FULL NOW (by PCT_USED, independent of fit quality; top &top_n) ==
PROMPT     SEV: CRIT>=&nf_crit%, WARN>=&nf_warn% used. A tablespace can be nearly full
PROMPT     today even when its growth is too flat/erratic to forecast.

SELECT NVL(c.db_pdb, TO_CHAR(f.con_dbid)) AS db_pdb,
       f.tablespace_name,
       f.pct_used,
       f.cur_used    / 1024 / 1024 / 1024 AS cur_gb,
       f.limit_bytes / 1024 / 1024 / 1024 AS limit_gb,
       f.days_to_full,
       CASE WHEN f.pct_used >= &nf_crit THEN 'CRIT'
            WHEN f.pct_used >= &nf_warn THEN 'WARN'
            ELSE 'ok'  END                AS sev,
       f.quality
FROM   capf_tbspc_forecast f
LEFT   JOIN capr_container c
  ON   c.dbid = f.dbid AND c.con_dbid = f.con_dbid
WHERE  f.pct_used IS NOT NULL
ORDER  BY f.pct_used DESC
FETCH FIRST &top_n ROWS ONLY;

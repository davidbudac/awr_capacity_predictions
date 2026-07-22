--
-- 01_days_to_full.sql -- tablespaces ranked by days-to-full (quality OK).
-- Consumes CAPF_TBSPC_FORECAST only. WARN/CRIT from CAP_CONFIG (&dtf_warn/&dtf_crit).
--
PROMPT
PROMPT == 1. TABLESPACES BY DAYS-TO-FULL (quality=OK; top &top_n) ==
PROMPT    SEV: CRIT<=&dtf_crit days, WARN<=&dtf_warn days. ACCEL>1.5 = growth accelerating.

COLUMN con_dbid        FORMAT 99999999999   HEADING 'CON_DBID'
COLUMN tablespace_name FORMAT A18           HEADING 'TABLESPACE'
COLUMN cur_gb          FORMAT 99990.00      HEADING 'CUR_GB'
COLUMN limit_gb        FORMAT 99990.00      HEADING 'LIMIT_GB'
COLUMN slope_mb        FORMAT 999990.000    HEADING 'MB/DAY'
COLUMN days_to_full    FORMAT 99999990      HEADING 'DAYS_FULL'
COLUMN sev             FORMAT A4            HEADING 'SEV'
COLUMN accel           FORMAT 990.00        HEADING 'ACCEL'

SELECT con_dbid,
       tablespace_name,
       cur_used    / 1024 / 1024 / 1024 AS cur_gb,
       limit_bytes / 1024 / 1024 / 1024 AS limit_gb,
       slope_bpd   / 1024 / 1024        AS slope_mb,
       days_to_full,
       CASE WHEN days_to_full <= &dtf_crit THEN 'CRIT'
            WHEN days_to_full <= &dtf_warn THEN 'WARN'
            ELSE 'ok'  END              AS sev,
       accel_ratio                      AS accel
FROM   capf_tbspc_forecast
WHERE  quality = 'OK'
  AND  days_to_full IS NOT NULL
ORDER  BY days_to_full
FETCH FIRST &top_n ROWS ONLY;

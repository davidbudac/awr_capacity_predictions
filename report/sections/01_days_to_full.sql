--
-- 01_days_to_full.sql -- tablespaces ranked by days-to-full + near-full-now.
-- FORMAT ONLY (M8.2): every number, label and severity marker comes from
-- CAPR_TBSPC_DAYS_TO_FULL, the same view the HTML report reads, so the two
-- drivers cannot drift. WARN/CRIT thresholds are baked into the view's
-- sev_dtf / sev_nearfull from CAP_CONFIG; the &dtf_*/&nf_* substitutions
-- below are only echoed in the PROMPT headers.
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
PROMPT     WORST/BEST: days-to-full range from the 95% CI on the growth slope
PROMPT     (WORST = plausibly fastest fill; BEST empty = might never fill).

COLUMN db_pdb          FORMAT A20           HEADING 'DB/PDB'
COLUMN tablespace_name FORMAT A18           HEADING 'TABLESPACE'
COLUMN pct_used        FORMAT 990.0         HEADING 'PCT_USED'
COLUMN cur_gb          FORMAT 99990.00      HEADING 'CUR_GIB'
COLUMN limit_gb        FORMAT 99990.00      HEADING 'LIMIT_GIB'
COLUMN slope_mb        FORMAT 999990.000    HEADING 'MIB/DAY'
COLUMN days_to_full    FORMAT 99999990      HEADING 'DAYS_FULL'
COLUMN dtf_worst       FORMAT 99999990      HEADING 'WORST'
COLUMN dtf_best        FORMAT 99999990      HEADING 'BEST'
COLUMN sev             FORMAT A4            HEADING 'SEV'
COLUMN quality         FORMAT A20           HEADING 'QUALITY'
COLUMN accel           FORMAT 990.00        HEADING 'ACCEL'

SELECT db_pdb,
       tablespace_name,
       pct_used,
       cur_gb,
       limit_gb,
       slope_mb,
       days_to_full,
       dtf_worst,
       dtf_best,
       sev_dtf AS sev,
       quality,
       accel
FROM   capr_tbspc_days_to_full
WHERE  days_to_full IS NOT NULL
  AND  rank_dtf <= &top_n
ORDER  BY rank_dtf;

PROMPT
PROMPT == 1b. NEAR-FULL NOW (by PCT_USED, independent of fit quality; top &top_n) ==
PROMPT     SEV: CRIT>=&nf_crit%, WARN>=&nf_warn% used. A tablespace can be nearly full
PROMPT     today even when its growth is too flat/erratic to forecast.

SELECT db_pdb,
       tablespace_name,
       pct_used,
       cur_gb,
       limit_gb,
       days_to_full,
       sev_nearfull AS sev,
       quality
FROM   capr_tbspc_days_to_full
WHERE  pct_used IS NOT NULL
  AND  rank_nearfull <= &top_n
ORDER  BY rank_nearfull;

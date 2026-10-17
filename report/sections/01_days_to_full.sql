--
-- 01_days_to_full.sql -- tablespaces ranked by days-to-full + near-full-now.
-- FORMAT ONLY (M8.2): every number, label and severity marker comes from
-- CAPR_TBSPC_DAYS_TO_FULL, the same view the HTML report reads, so the two
-- drivers cannot drift. sev_dtf / sev_nearfull are CAPR_SEVERITY's, the
-- severities CAPR_ALERTS raises (CAP_CONFIG thresholds or a tablespace's
-- CAP_TBSPC_OVERRIDE ones); the &dtf_*/&nf_* substitutions below are only
-- echoed in the PROMPT headers.
--
-- M7.1: the ranking no longer hides non-OK fits -- every computable
-- days_to_full appears WITH its quality marker (a LOW_CONFIDENCE estimate is
-- still a signal; the marker tells you how hard to trust it), and a second
-- "near-full now" ranking by PCT_USED is independent of fit quality entirely,
-- so a 97%-full tablespace with INSUFFICIENT_HISTORY can never vanish.
--
PROMPT
PROMPT == 1a. TABLESPACES BY DAYS-TO-FULL (any quality; top &top_n) ==
PROMPT     SEV: CRIT<=&dtf_crit days, WARN<=&dtf_warn days (or the tablespace's own override),
PROMPT     the severity CAPR_ALERTS raises. GATE says why a row in that window does not page:
PROMPT     low-q / short = the fit is not OK, cyclic = a purge cycle judged on its peak line,
PROMPT     stale = no longer reported (is_current N), lim<used = the limit is already under
PROMPT     the usage (1b pages it). ACCEL>1.5 = growth accelerating. Trust the estimate per
PROMPT     QUALITY (only OK is reliable).
PROMPT     WORST/BEST: days-to-full range from the 95% CI on the growth slope
PROMPT     (WORST = plausibly fastest fill; BEST empty = might never fill).
PROMPT     CYCLIC = a recurring purge cycle (CYC_D days apart), ranked after the rows with a
PROMPT     DAYS_FULL when it has none, and judged on its peaks: PEAK% = highest fill in the
PROMPT     window, DAYS_FULL = when the peak line reaches the limit (empty when the peaks
PROMPT     do not grow).
PROMPT     NEED_90_GIB = space to add so the worst case (upper 95% band) stays under the
PROMPT     limit for 90 days. ADD_BY = the worst-case fill date (last day + WORST).

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
COLUMN gate            FORMAT A8            HEADING 'GATE'
COLUMN quality         FORMAT A20           HEADING 'QUALITY'
COLUMN accel           FORMAT 990.00        HEADING 'ACCEL'
COLUMN cycle_days      FORMAT 9990          HEADING 'CYC_D'
COLUMN cycle_peak_pct  FORMAT 990.0         HEADING 'PEAK%'
COLUMN need_gib_90     FORMAT 9999990.00    HEADING 'NEED_90_GIB'
COLUMN add_by          FORMAT A10           HEADING 'ADD_BY'

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
       gate,
       quality,
       accel,
       cycle_days,
       cycle_peak_pct,
       need_gib_90,
       TO_CHAR(add_by_day, 'YYYY-MM-DD') AS add_by
FROM   capr_tbspc_days_to_full
WHERE  (days_to_full IS NOT NULL OR quality = 'CYCLIC')
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

--
-- 02_tbspc_forecast.sql -- per-tablespace REGR projections + ESM (when trained).
-- FORMAT ONLY (M8.2): everything comes from CAPR_TBSPC_FORECAST
-- (ddl/55_report_views_ml.sql), which already resolves DB/PDB, converts to
-- GiB and joins the Tier 2 ESM +30 point. The HTML report reads the same view.
--
-- M7.4: bounded. The view decides reportability (is_reportable: growing, or
-- near-full, or >= report_min_gb GiB) and ranks (rank_report: reportable
-- first, growing first, then biggest); this file only applies the WHERE, the
-- same one report_html.sql applies, so a 500-tablespace database prints
-- top_n interesting rows instead of 500. CAPR_TBSPC_FORECAST still has them all.
--
PROMPT
PROMPT == 2. TABLESPACE FORECAST (GiB): current / +30 / +90 / +180, plus ESM +30 ==
PROMPT    Showing &ts_shown of &ts_total tablespace(s): growing, near-full, or >= &min_gb GiB
PROMPT    used (knob report_min_gb), capped at top &top_n -- CAPR_TBSPC_FORECAST has all.
PROMPT    QUALITY: OK | LOW_CONFIDENCE (R2<gate) | FLAT (no growth) | INSUFFICIENT_HISTORY.
PROMPT    ESM (Tier 2) only reaches +30 on 19c (hard horizon cap); +90/180 are REGR.
PROMPT    180_LO/180_HI: 95% prediction band on the +180 projection (widest printed
PROMPT    horizon); the +30/+90/+365 bands are in CAPF_TBSPC_FORECAST (proj_*_lo/hi).

COLUMN db_pdb          FORMAT A20         HEADING 'DB/PDB'
COLUMN tablespace_name FORMAT A16         HEADING 'TABLESPACE'
COLUMN n               FORMAT 9990         HEADING 'TRAIN_N'
COLUMN cur_gb          FORMAT 99990.00     HEADING 'CUR_GIB'
COLUMN p30             FORMAT 99990.00     HEADING '+30_GIB'
COLUMN p90             FORMAT 99990.00     HEADING '+90_GIB'
COLUMN p180            FORMAT 99990.00     HEADING '+180_GIB'
COLUMN p180_lo         FORMAT 99990.00     HEADING '180_LO'
COLUMN p180_hi         FORMAT 99990.00     HEADING '180_HI'
COLUMN r2              FORMAT 90.999        HEADING 'R2'
COLUMN quality         FORMAT A20          HEADING 'QUALITY'
COLUMN esm30           FORMAT 99990.00     HEADING 'ESM+30'

SELECT db_pdb,
       tablespace_name,
       train_n AS n,
       cur_gb,
       p30,
       p90,
       p180,
       p180_lo,
       p180_hi,
       r2,
       quality,
       esm30
FROM   capr_tbspc_forecast
WHERE  is_reportable = 'Y'
  AND  rank_report <= &top_n
ORDER  BY rank_report;

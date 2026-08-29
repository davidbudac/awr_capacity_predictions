--
-- 07_series.sql -- fixed-ceiling series: processes/sessions, redo, DB size (M11).
-- FORMAT ONLY (M8.2 convention): every number, label and severity marker comes
-- from CAPR_SERIES, the same view the HTML report reads.
--
-- Unlike a tablespace, these series each have (or lack) a single hard ceiling
-- that is not a byte count: the `processes` / `sessions` init parameters, the
-- summed tablespace ceilings, or -- for redo -- no ceiling at all. They are
-- listed together because the arithmetic is identical: fit a line, ask when it
-- reaches SAT% of the limit.
--
PROMPT
PROMPT == 7. FIXED-CEILING SERIES (processes / sessions / redo / total DB size) ==
PROMPT     PROCESSES, SESSIONS  peak concurrency (AWR max_utilization, a
PROMPT                          high-water mark since instance startup) against
PROMPT                          the init parameter. RAC: summed over instances.
PROMPT     REDO_GB_DAY          redo written per day, GiB. No ceiling -- it is a
PROMPT                          trend for FRA / archive-destination sizing.
PROMPT     DB_SIZE_GB           total permanent-tablespace bytes used, vs the sum
PROMPT                          of the same tablespaces' ceilings.
PROMPT     DAYS_LIM = projected days until the series reaches SAT (the
PROMPT     series_sat_pct% of LIMIT shown), empty when there is no ceiling or no
PROMPT     growth. WORST/BEST bound it with the 95% CI on the slope
PROMPT     (BEST empty = might never get there). Trust it per QUALITY.

COLUMN db_pdb       FORMAT A20           HEADING 'DB/PDB'
COLUMN series       FORMAT A12           HEADING 'SERIES'
COLUMN unit         FORMAT A11           HEADING 'UNIT'
COLUMN n            FORMAT 9990          HEADING 'TRAIN_N'
COLUMN cur_val      FORMAT 99999990.00   HEADING 'CURRENT'
COLUMN cur_limit    FORMAT 99999990.00   HEADING 'LIMIT'
COLUMN sat_value    FORMAT 99999990.00   HEADING 'SAT'
COLUMN pct_of_limit FORMAT 990.0         HEADING 'PCT_LIM'
COLUMN slope_day    FORMAT 9999990.0000  HEADING 'SLOPE/DAY'
COLUMN r2           FORMAT 90.999        HEADING 'R2'
COLUMN days_lim     FORMAT 99999990      HEADING 'DAYS_LIM'
COLUMN limit_worst  FORMAT 99999990      HEADING 'WORST'
COLUMN limit_best   FORMAT 99999990      HEADING 'BEST'
COLUMN sev          FORMAT A4            HEADING 'SEV'
COLUMN quality      FORMAT A20           HEADING 'QUALITY'

SELECT db_pdb,
       series,
       unit,
       train_n       AS n,
       cur_val,
       cur_limit,
       sat_value,
       pct_of_limit,
       slope_per_day AS slope_day,
       r2,
       days_to_limit AS days_lim,
       limit_worst,
       limit_best,
       sev,
       quality
FROM   capr_series
ORDER  BY rank_series;

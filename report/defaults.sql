--
-- report/defaults.sql -- canonical defaults for report/report.sql.
-- =====================================================================
-- report.sql does NOT load this itself (so an explicit caller override via
-- DEFINE before @report.sql is never clobbered). Load it first for defaults:
--   sqlplus user/pw@svc
--   SQL> @report/defaults.sql
--   SQL> @report/report.sql
--
DEFINE top_n        = 10        -- rows in the days-to-full ranking
DEFINE anomaly_days = 30        -- trailing days of anomalies to print/chart
-- show_esm: AUTO = show the Tier 2 compare only if OK models exist (else a
-- one-line hint); Y = always show the section; N = skip it entirely.
DEFINE show_esm     = 'AUTO'

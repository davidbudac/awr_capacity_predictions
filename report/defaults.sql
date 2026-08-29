--
-- report/defaults.sql -- canonical defaults for the two report drivers.
-- =====================================================================
-- report/report.sql and report/report_html.sql BOTH include this file first,
-- then override each value with the matching positional argument if one was
-- passed (M7.6):
--
--   @report/report.sql                 -- everything from this file
--   @report/report.sql 5               -- top_n=5, the rest from this file
--   @report/report.sql 5 7 N           -- top_n=5, anomaly_days=7, show_esm=N
--   @report/report_html.sql 25 60 Y    -- same three, same order
--
-- So: edit THIS file to change the defaults for every run; pass positional
-- arguments to change one run. Loading it by hand is harmless but pointless --
-- the drivers load it themselves, which is what keeps a bare
-- `@report/report.sql` from prompting for an undefined substitution variable.
--
DEFINE top_n        = 10        -- rows in the days-to-full / forecast rankings
DEFINE anomaly_days = 30        -- trailing days of anomalies to print/chart
-- show_esm: AUTO = show the Tier 2 compare only if OK models exist (else a
-- one-line hint); Y = always show the section; N = skip it entirely.
DEFINE show_esm     = 'AUTO'

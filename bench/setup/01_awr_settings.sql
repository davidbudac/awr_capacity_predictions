-- bench/setup/01_awr_settings.sql -- run in CDB$ROOT as SYSDBA.
--
-- The shipped defaults on this test DB (1-hour snapshots, 8-day retention)
-- cannot feed the toolkit: CAP_CONFIG.min_train_days is 14 *daily* points, and
-- an hourly snapshot gives a coarse intra-day picture. Move to 15-minute
-- snapshots and 35 days of retention.
--
--   interval  = 15    minutes
--   retention = 50400 minutes = 35 days
--
-- Reversed by bench/teardown.sql. Costs SYSAUX space (~1.8 GB used against a
-- 64 GB max here), which is itself a legitimate growth series for the report.
SET SERVEROUTPUT ON
SET VERIFY OFF

DECLARE
    v_int  NUMBER;
    v_ret  NUMBER;
BEGIN
    SELECT EXTRACT(DAY FROM snap_interval) * 1440
         + EXTRACT(HOUR FROM snap_interval) * 60
         + EXTRACT(MINUTE FROM snap_interval),
           EXTRACT(DAY FROM retention) * 1440
         + EXTRACT(HOUR FROM retention) * 60
         + EXTRACT(MINUTE FROM retention)
      INTO v_int, v_ret
      FROM dba_hist_wr_control
     WHERE dbid = (SELECT dbid FROM v$database);

    DBMS_OUTPUT.PUT_LINE('before: interval=' || v_int || 'min retention=' || v_ret || 'min');
END;
/

BEGIN
    DBMS_WORKLOAD_REPOSITORY.MODIFY_SNAPSHOT_SETTINGS(
        interval  => 15,
        retention => 50400);
END;
/

SELECT snap_interval, retention FROM dba_hist_wr_control;

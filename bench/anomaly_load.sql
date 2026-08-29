-- bench/anomaly_load.sql -- deliberate tablespace-growth outlier.
--
-- Bulk-loads roughly &mb MiB into SOETBS under the SOE schema, so one day's
-- used_bytes delta lands far outside the rolling median/MAD baseline and
-- CAPA_TBSPC_ANOM has a real anomaly to catch (CAP_CONFIG.mad_k = 3, with
-- abs_floor_bytes = 100 MiB as the floor -- hence the 400 MiB default).
--
-- The table is dropped by bench/teardown.sql, and re-running this script
-- appends another chunk. Expects DEFINEs: owner, mb
SET SERVEROUTPUT ON
SET VERIFY OFF

DECLARE
    v_rows   PLS_INTEGER;
    v_exists PLS_INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_exists
      FROM dba_tables WHERE owner = UPPER('&owner') AND table_name = 'CAP_BENCH_ANOMALY';

    IF v_exists = 0 THEN
        EXECUTE IMMEDIATE 'CREATE TABLE &owner..cap_bench_anomaly (
            id     NUMBER,
            loaded DATE,
            filler VARCHAR2(1000)) TABLESPACE soetbs';
    END IF;

    -- ~1 KiB per row -> mb * 1024 rows.
    v_rows := &mb * 1024;

    EXECUTE IMMEDIATE '
        INSERT /*+ APPEND */ INTO &owner..cap_bench_anomaly (id, loaded, filler)
        SELECT LEVEL, SYSDATE, RPAD(''x'', 1000, ''x'')
          FROM dual CONNECT BY LEVEL <= :n' USING v_rows;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('anomaly load: ' || v_rows || ' rows (~&mb MiB) into &owner..cap_bench_anomaly');
END;
/

SELECT ROUND(SUM(bytes) / 1024 / 1024) soetbs_mb FROM dba_data_files WHERE tablespace_name = 'SOETBS';

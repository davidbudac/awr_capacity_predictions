# ORDS module for Grafana

`awrcap_module.sql` publishes the suite's `CAPR_*` views as the ORDS REST
module `awrcap`. The endpoints and their columns are defined in
[`../API.md`](../API.md). Every handler is a `GET` that returns all matching
rows in one response (`p_items_per_page => 0`, verified on ORDS 26.3: a
1251-row response came back with `"hasMore":false`).

The module writes only ORDS metadata (in `ORDS_METADATA`). The handlers run
read-only `SELECT`s against the suite views. The handlers are public, so if
the network is not trusted, protect the module with an ORDS privilege.

## Scripts

| Script | What it does |
|---|---|
| `awrcap_module.sql [schema] [alias]` | REST-enables the schema (URL alias defaults to the lower-case schema name, `p_auto_rest_auth => FALSE`) and defines the `awrcap` module (base path `/awrcap/`) with six GET handlers. Running it again replaces the module. |
| `awrcap_module_drop.sql [schema]` | Deletes the `awrcap` module. The schema stays REST-enabled. Running it when the module is already gone does nothing. |

Both scripts take the schema from `&1`, or from `CURRENT_SCHEMA` when `&1` is
not given. When the session user is the schema owner, the scripts call
`ORDS.*`. Any other user calls `ORDS_ADMIN.*` with `p_schema`. That user needs
`ORDS_ADMINISTRATOR_ROLE` or `EXECUTE ANY PROCEDURE`. SYSDBA has the second.

```
-- as the owner
SQL> @grafana/ords/awrcap_module.sql
-- as SYSDBA, in the PDB that holds the suite
SQL> ALTER SESSION SET CONTAINER = PDB1;
SQL> @grafana/ords/awrcap_module.sql CAPDEMO
```

The `from` and `to` query parameters are mapped to the bind variables
`:p_from` and `:p_to` with `DEFINE_PARAMETER`, because `:from` and `:to` are
not legal bind names. `kind`, `db` and `series` bind implicitly.

`from` and `to` are parsed with
`TO_TIMESTAMP_TZ(…, 'YYYY-MM-DD"T"HH24:MI:SS.FF3TZR')`. This mask accepts both
`2026-10-01T00:00:00Z` and the `2026-10-01T00:00:00.000Z` that Grafana's
`${__from:date:iso}` sends. A daily point is in range when
`TRUNC(from) <= ts <= to`. When `from` is missing, it defaults to
`TRUNC(SYSDATE) - 120`. When `to` is missing, it defaults to `SYSDATE`. A
request without `kind` on `series` or `forecast` returns an empty `items`
array.

## Lab deployment (dbmint, done 2026-10-17)

The suite runs in schema `CAPDEMO` in `PDB1` of `cdb1`, in the dbmint VM.
The listener is `192.168.56.111:1521`, and the service is `pdb1.world`. The
VM has no Java, and the SYS password is not known. So ORDS runs in Docker on
the host and is installed with a dedicated admin user instead of SYS.
Image: `container-registry.oracle.com/database/ords:latest` (ORDS
26.3.0.r2721811). Database: 19.27. ORDS 26.3 installed against 19c without
complaint.

1. Extract the installer-privileges script from the image and copy it to the
   VM.

   ```
   docker run --rm --entrypoint cat container-registry.oracle.com/database/ords:latest \
       /opt/oracle/ords/scripts/installer/ords_installer_privileges.sql > /tmp/ordsx/ords_installer_privileges.sql
   scp -P 2200 /tmp/ordsx/ords_installer_privileges.sql oracle@dbmint:/tmp/
   ```

2. Generate the passwords into `grafana/.ords.env` (gitignored, mode 600). The
   file holds `ORDS_INSTALLER_PASSWORD` and `ORDS_PUBLIC_USER_PASSWORD`.

3. As SYSDBA in `PDB1`, create the installer user and grant it the
   privileges:

   ```
   ALTER SESSION SET CONTAINER = PDB1;
   CREATE USER ords_installer IDENTIFIED BY "<ORDS_INSTALLER_PASSWORD>";
   GRANT CREATE SESSION TO ords_installer;
   @/tmp/ords_installer_privileges.sql ORDS_INSTALLER
   ```

   The script granted 37 system privileges and 46 object privileges.

4. Install ORDS into `PDB1`. This creates `ORDS_METADATA` and
   `ORDS_PUBLIC_USER`. The container's own entrypoint needs the SYS password,
   so call the `ords` CLI directly. `--password-stdin` reads two lines: the
   admin password, then the password for the new `ORDS_PUBLIC_USER`. The
   container runs as uid 54321 and must be able to write to the config
   directory during the install. The directory was opened to mode 777 for
   the install and set back to 755 after it.

   ```
   . grafana/.ords.env
   printf '%s\n%s\n' "$ORDS_INSTALLER_PASSWORD" "$ORDS_PUBLIC_USER_PASSWORD" |
   docker run --rm -i -v $PWD/grafana/ords/config:/etc/ords/config --entrypoint ords \
       container-registry.oracle.com/database/ords:latest --config /etc/ords/config install \
       --admin-user ORDS_INSTALLER --db-hostname 192.168.56.111 --db-port 1521 \
       --db-servicename pdb1.world --feature-sdw false --feature-db-api false \
       --feature-rest-enabled-sql false --log-folder /tmp --password-stdin
   ```

   `grafana/ords/config/` now holds `pool.xml`, `settings.xml` and the wallet
   with the `ORDS_PUBLIC_USER` password. Everything in it except `.gitkeep`
   is gitignored. Keep it, and `.ords.env`, off the VM: rsync with
   `--exclude grafana/.ords.env --exclude grafana/ords/config`.

5. Start ORDS. Host port 8080 is already taken on the lab host, by
   `lab-orders-app` on 127.0.0.1:8080, so ORDS is published on 8181.

   ```
   docker run -d --name awrcap-ords -p 8181:8080 -v $PWD/grafana/ords/config:/etc/ords/config \
       --entrypoint ords container-registry.oracle.com/database/ords:latest --config /etc/ords/config serve
   ```

6. Sync the repo to the VM. Install the two view files in `CAPDEMO`, then
   publish the module:

   ```
   rsync -az --delete -e 'ssh -p 2200' --exclude .git --exclude reports \
       --exclude grafana/.ords.env --exclude grafana/ords/config ./ oracle@dbmint:~/awr_capacity_predictions/
   # on the VM, from ~/awr_capacity_predictions, sqlplus / as sysdba:
   ALTER SESSION SET CONTAINER = PDB1;
   ALTER SESSION SET CURRENT_SCHEMA = CAPDEMO;
   @ddl/45_report_views.sql
   @ddl/55_report_views_ml.sql
   SELECT object_name FROM all_objects
   WHERE  owner = SYS_CONTEXT('USERENV','CURRENT_SCHEMA') AND status <> 'VALID';   -- no rows
   @grafana/ords/awrcap_module.sql CAPDEMO
   ```

7. Check the endpoints:

   ```
   curl -s 'http://localhost:8181/ords/capdemo/awrcap/containers'
   curl -s 'http://localhost:8181/ords/capdemo/awrcap/series?kind=TBSPC&from=2026-06-01T00:00:00.000Z&to=2026-10-17T00:00:00.000Z'
   ```

Base URL: `http://localhost:8181/ords/capdemo/awrcap/`.

To remove everything, run `@grafana/ords/awrcap_module_drop.sql CAPDEMO` and
`docker rm -f awrcap-ords`. To remove ORDS from the PDB, run `ords uninstall`
with the same admin user.

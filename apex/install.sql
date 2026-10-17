-- Install or replace the AWR Capacity APEX application.
--
-- Run as the parsing schema owner or as a user with APEX_ADMINISTRATOR_ROLE,
-- from the apex/ directory (or as @apex/install.sql from the repo root):
--   sqlplus <user>@<pdb> @install.sql [workspace] [schema] [app_id] [GENERATE_OFFSET]
-- Defaults: workspace AWRCAP, schema AWRCAP, application 110.  Re-running
-- replaces the application.  Pass GENERATE_OFFSET only for a second copy of
-- the app in the same instance (component ids are fixed and would collide).
-- The app only reads the suite's CAPR_* views and CAP_CONFIG; it writes
-- nothing but APEX session collections.
set define '&' verify off feedback off serveroutput on
whenever sqlerror exit sql.sqlcode rollback
column 1 new_value 1 noprint
column 2 new_value 2 noprint
column 3 new_value 3 noprint
column 4 new_value 4 noprint
select '' "1", '' "2", '' "3", '' "4" from dual where rownum = 0;
column ws new_value ws noprint
column sch new_value sch noprint
column app new_value app noprint
column app_alias new_value app_alias noprint
column offset_mode new_value offset_mode noprint
select upper(nvl(trim('&1'), 'AWRCAP')) ws,
       upper(nvl(trim('&2'), 'AWRCAP')) sch,
       to_char(to_number(nvl(trim('&3'), '110'))) app,
       case when nvl(trim('&3'), '110') = '110' then 'AWRCAP' else 'AWRCAP' || trim('&3') end app_alias,
       upper(trim('&4')) offset_mode
  from dual;
prompt AWR Capacity: workspace &ws, schema &sch, application &app (alias &app_alias)
declare
  l_owner_ws varchar2(255);
  l_owner_alias varchar2(255);
begin
  for a in (select workspace, alias from apex_applications where application_id = &app) loop
    l_owner_ws := a.workspace;
    l_owner_alias := a.alias;
  end loop;
  if l_owner_ws is not null and (l_owner_ws <> '&ws' or l_owner_alias <> '&app_alias') then
    raise_application_error(-20001, 'Application &app belongs to ' || l_owner_alias || ' in workspace '
      || l_owner_ws || '; refusing to overwrite it. Pass a free application id as the third argument.');
  end if;
  if '&offset_mode' is not null and '&offset_mode' <> 'GENERATE_OFFSET' then
    raise_application_error(-20002, 'Fourth argument must be GENERATE_OFFSET or omitted.');
  end if;
  apex_application_install.set_workspace('&ws');
  apex_application_install.set_schema('&sch');
  apex_application_install.set_application_id(&app);
  apex_application_install.set_application_alias('&app_alias');
  if '&offset_mode' = 'GENERATE_OFFSET' then
    apex_application_install.generate_offset;
  end if;
end;
/
@@awrcap_app.sql
set define '&' feedback off verify off
select 'Installed application ' || application_id || ' (' || alias || ') in workspace ' || workspace
       || ': ' || pages || ' pages' as result
  from apex_applications where application_id = &app;
begin
  apex_application_install.clear_all;
end;
/
undefine 1 2 3 4 ws sch app app_alias offset_mode

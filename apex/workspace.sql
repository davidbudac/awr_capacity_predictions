-- Optional instance-admin step for the AWR Capacity APEX app: create the
-- workspace (if missing) and its two accounts, ADMIN (developer) and
-- <WORKSPACE>_VIEWER (end user: no App Builder, no SQL Workshop).
--
-- Run as SYSTEM or any APEX_ADMINISTRATOR_ROLE user in the PDB:
--   sqlplus system@<pdb> @workspace.sql [workspace] [schema] [admin_pw viewer_pw]
-- Defaults: workspace AWRCAP, primary schema AWRCAP.  The two passwords are
-- read with hidden ACCEPT prompts.  Positional arguments 3 and 4 act as the
-- prompt defaults, so a non-interactive run passes them with stdin from
-- /dev/null.  Do not pipe both passwords: a hidden ACCEPT reads the whole
-- piped buffer, so the guard below rejects a password with a line break.
-- A blank password leaves an existing account untouched, so re-running
-- against a configured workspace changes nothing; a missing account is only
-- created when it gets a password.
set define '&' verify off feedback off serveroutput on
whenever sqlerror exit sql.sqlcode rollback
column 1 new_value 1 noprint
column 2 new_value 2 noprint
column 3 new_value 3 noprint
column 4 new_value 4 noprint
select '' "1", '' "2", '' "3", '' "4" from dual where rownum = 0;
column ws new_value ws noprint
column sch new_value sch noprint
select upper(nvl(trim('&1'), 'AWRCAP')) ws, upper(nvl(trim('&2'), 'AWRCAP')) sch from dual;
accept admin_pw char prompt 'Password for ADMIN (blank keeps the current one): ' hide default '&3'
accept viewer_pw char prompt 'Password for &ws._VIEWER (blank keeps the current one): ' hide default '&4'
declare
  l_ws constant varchar2(255) := '&ws';
  l_schema constant varchar2(128) := '&sch';
  l_count pls_integer;

  procedure ensure_user(p_name in varchar2, p_password in varchar2, p_privs in varchar2) is
    l_builder constant varchar2(1) := case when p_privs is null then 'N' else 'Y' end;
  begin
    if instr(p_password, chr(10)) > 0 then
      raise_application_error(-20001, 'Password for ' || p_name || ' contains a line break; '
        || 'type it at the prompt or pass it as an argument');
    end if;
    select count(*) into l_count from apex_workspace_apex_users where workspace_name = l_ws and user_name = p_name;
    if l_count = 0 and p_password is null then
      dbms_output.put_line('User ' || p_name || ' missing; rerun with a password to create it');
    elsif l_count = 0 then
      apex_util.create_user(p_user_name => p_name, p_web_password => p_password, p_developer_privs => p_privs,
        p_default_schema => l_schema, p_change_password_on_first_use => 'N',
        p_email_address => lower(p_name) || '@' || lower(l_ws) || '.local',
        p_allow_app_building_yn => l_builder, p_allow_sql_workshop_yn => l_builder,
        p_allow_team_development_yn => l_builder);
      dbms_output.put_line('User ' || p_name || ' created');
    elsif p_password is not null then
      apex_util.edit_user(p_user_id => apex_util.get_user_id(p_name), p_user_name => p_name,
        p_web_password => p_password, p_new_password => p_password, p_default_schema => l_schema,
        p_developer_roles => p_privs, p_change_password_on_first_use => 'N');
      dbms_output.put_line('User ' || p_name || ' password reset');
    else
      dbms_output.put_line('User ' || p_name || ' unchanged');
    end if;
  end;
begin
  select count(*) into l_count from apex_workspaces where workspace = l_ws;
  if l_count = 0 then
    apex_instance_admin.add_workspace(p_workspace => l_ws, p_primary_schema => l_schema);
    dbms_output.put_line('Workspace ' || l_ws || ' created for schema ' || l_schema);
  else
    select count(*) into l_count from apex_workspace_schemas where workspace_name = l_ws and schema = l_schema;
    if l_count = 0 then
      apex_instance_admin.add_schema(p_workspace => l_ws, p_schema => l_schema);
      dbms_output.put_line('Schema ' || l_schema || ' mapped to workspace ' || l_ws);
    else
      dbms_output.put_line('Workspace ' || l_ws || ' already exists');
    end if;
  end if;
  apex_util.set_security_group_id(apex_util.find_security_group_id(l_ws));
  ensure_user('ADMIN', q'~&admin_pw~', 'ADMIN:CREATE:DATA_LOADER:EDIT:HELP:MONITOR:SQL');
  ensure_user(l_ws || '_VIEWER', q'~&viewer_pw~', null);
  commit;
end;
/
undefine 1 2 3 4 ws sch admin_pw viewer_pw

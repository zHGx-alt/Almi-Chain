-- =============================================================================
-- Almi-Chain · 08: login accounts with least privilege
-- Creates the real accounts and puts them in the group roles from 03-roles.sql:
--   pos_app    -> app_role   (the till software: reads, sells, never deletes invoices or runs DDL)
--   reporting  -> read_role  (manager or accountant: read-only)
-- Passwords are NOT in the repository. Typed on the command line they would end up in
-- the shell history, so read them first without echoing:
--   read -rsp 'pos_app: ' POS_PASSWORD; echo; read -rsp 'reporting: ' REPORTING_PASSWORD; echo
--   psql -d almi_chain -v ON_ERROR_STOP=1 -v pos_password="$POS_PASSWORD" \
--        -v reporting_password="$REPORTING_PASSWORD" -f 08-users.sql
--   unset POS_PASSWORD REPORTING_PASSWORD
-- Repeatable: if the accounts exist, only the password changes.
-- Requires 01, 02 and 03; run as the owner of the tables.
-- =============================================================================

\if :{?pos_password}
\else
  \echo 'Missing password: -v pos_password=...'
  \quit
\endif
\if :{?reporting_password}
\else
  \echo 'Missing password: -v reporting_password=...'
  \quit
\endif

BEGIN;

-- Create or update each account. format(%L) quotes the password safely.
SELECT format(CASE WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pos_app')
                   THEN 'ALTER ROLE pos_app LOGIN PASSWORD %L'
                   ELSE 'CREATE ROLE pos_app LOGIN PASSWORD %L' END, :'pos_password') \gexec
SELECT format(CASE WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'reporting')
                   THEN 'ALTER ROLE reporting LOGIN PASSWORD %L'
                   ELSE 'CREATE ROLE reporting LOGIN PASSWORD %L' END, :'reporting_password') \gexec

-- No admin privileges, and a connection limit in case a password leaks.
ALTER ROLE pos_app   NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION CONNECTION LIMIT 10;
ALTER ROLE reporting NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION CONNECTION LIMIT 3;

GRANT app_role  TO pos_app;
GRANT read_role TO reporting;

-- Only these accounts (and the owner) can connect to this database.
SELECT format('REVOKE CONNECT ON DATABASE %I FROM PUBLIC', current_database()) \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO pos_app, reporting', current_database()) \gexec

COMMIT;

\echo 'Accounts and groups:'
SELECT r.rolname AS account, r.rolcanlogin AS login, r.rolconnlimit AS max_connections,
       string_agg(g.rolname, ', ') AS groups
FROM pg_roles r
LEFT JOIN pg_auth_members m ON m.member = r.oid
LEFT JOIN pg_roles g        ON g.oid = m.roleid
WHERE r.rolname IN ('pos_app', 'reporting')
GROUP BY r.rolname, r.rolcanlogin, r.rolconnlimit
ORDER BY r.rolname;

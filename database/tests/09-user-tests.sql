-- =============================================================================
-- Almi-Chain · 09: least-privilege tests with the real accounts
-- Runs TWICE, once with each account from 08-users.sql:
--   psql -d almi_chain -U pos_app   -v account=pos_app   -f 09-user-tests.sql
--   psql -d almi_chain -U reporting -v account=reporting -f 09-user-tests.sql
-- Each test prints OK when the result is the expected one. Everything ends in
-- ROLLBACK: it leaves no data. Needs the data from 06-sample-data.sql.
-- =============================================================================

\set ON_ERROR_STOP 1
\echo '== Tests for account' :account '(connected as' :USER ')'

BEGIN;

CREATE PROCEDURE pg_temp.check_access(p_name TEXT, p_sql TEXT, p_must_work BOOLEAN)
LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE p_sql;
    EXCEPTION WHEN OTHERS THEN
        IF p_must_work THEN
            RAISE EXCEPTION 'FAILED %: it should be allowed and is not (%)', p_name, SQLERRM;
        END IF;
        RAISE NOTICE 'OK     %  (rejected: %)', p_name, SQLERRM;
        RETURN;
    END;
    IF NOT p_must_work THEN
        RAISE EXCEPTION 'FAILED %: it should be rejected and was allowed', p_name;
    END IF;
    RAISE NOTICE 'OK     %  (allowed)', p_name;
END $$;

-- Common to both accounts: no DDL and no changes to issued invoices.
CALL pg_temp.check_access('read the menu', 'SELECT count(*) FROM dish', TRUE);
CALL pg_temp.check_access('create a table (DDL)', 'CREATE TABLE public.intruder (id int)', FALSE);
CALL pg_temp.check_access('drop the invoice table (DDL)', 'DROP TABLE invoice', FALSE);
CALL pg_temp.check_access('modify an issued invoice (R-04)', 'UPDATE invoice SET payment_method = ''other''', FALSE);
CALL pg_temp.check_access('delete invoices (R-04)', 'DELETE FROM invoice_line', FALSE);
CALL pg_temp.check_access('create a restaurant', 'INSERT INTO restaurant (name, address, city) VALUES (''X'', ''X'', ''X'')', FALSE);

\if :{?account}
\else
  \set account none
\endif
SELECT :'account' = 'pos_app' AS is_pos \gset

\if :is_pos
-- The POS sells and registers customers, but does not change the configuration.
CALL pg_temp.check_access('issue an invoice', $q$
    INSERT INTO invoice (series, payment_method, employee_id, device_id)
    SELECT 'TEST', 'cash', e.employee_id, d.device_id
    FROM employee e JOIN device d ON d.restaurant_id = e.restaurant_id
    JOIN device_model m ON m.model_id = d.model_id AND m.device_type = 'pos'
    WHERE e.national_id = '00000002W' LIMIT 1 $q$, TRUE);
CALL pg_temp.check_access('register a customer', 'INSERT INTO customer (name) VALUES (''Test customer'')', TRUE);
CALL pg_temp.check_access('change a device IP', 'UPDATE device SET ip = ''10.9.9.9''', FALSE);
\else
-- Reporting: read-only.
CALL pg_temp.check_access('query total sales', 'SELECT sum(total) FROM v_invoice_totals', TRUE);
CALL pg_temp.check_access('issue an invoice', 'INSERT INTO invoice (series, payment_method, employee_id, device_id) VALUES (''X'', ''cash'', 1, 1)', FALSE);
CALL pg_temp.check_access('register a customer', 'INSERT INTO customer (name) VALUES (''X'')', FALSE);
\endif

ROLLBACK;
\echo '== Done: all tests for' :account 'passed'

-- =============================================================================
-- Almi-Chain · 03: group roles and privileges (least privilege, R-04)
-- Group roles cannot log in (NOLOGIN). People and services get their own login role,
-- with a password kept outside the repository, and join a group (08-users.sql).
-- Requires 01 and 02; run as the owner of the tables.
-- =============================================================================

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_role') THEN
        CREATE ROLE app_role NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'read_role') THEN
        CREATE ROLE read_role NOLOGIN;
    END IF;
END $$;

-- Start from zero: nobody but the owner can touch anything.
REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM PUBLIC, app_role, read_role;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM PUBLIC, app_role, read_role;

-- Application (POS / ERP): reads everything, manages day-to-day data.
GRANT SELECT ON ALL TABLES IN SCHEMA public TO app_role;
GRANT INSERT, UPDATE ON customer, dish, ingredient, stock, recipe,
                        marketing_campaign, campaign_send, employee    TO app_role;
GRANT DELETE ON campaign_send, recipe                                  TO app_role;
-- Purchasing and allergens are maintained by the application. Price history is
-- written only by R-07: the application can read it but not change it.
GRANT INSERT, UPDATE ON supplier, supply                               TO app_role;
GRANT INSERT, DELETE ON dish_allergen                                  TO app_role;
GRANT DELETE ON supply                                                 TO app_role;

-- R-04: issued invoices are never modified or deleted. INSERT only.
GRANT INSERT ON invoice, invoice_line TO app_role;

-- Restaurant and device configuration: owner (administrator) only.

-- Read-only (reports, logical backups, accounting).
GRANT SELECT ON ALL TABLES IN SCHEMA public TO read_role;

COMMIT;

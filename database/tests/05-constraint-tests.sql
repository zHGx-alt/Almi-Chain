-- =============================================================================
-- Almi-Chain · 05: tests for the constraints and business rules
-- Run after 01, 02 and 03, on an empty test database:
--   psql -d almi_chain -v ON_ERROR_STOP=1 -f 05-constraint-tests.sql
-- Everything happens inside a transaction that ends in ROLLBACK: it leaves no data.
-- WARNING: it empties the tables and restarts the identities first (inside the
-- transaction, so that is undone too). Use ONLY on a test database.
-- A "must fail" test is OK when the database rejects the statement.
-- =============================================================================

BEGIN;

TRUNCATE restaurant, employee, customer, device_model, device, dish, ingredient,
         stock, recipe, invoice, invoice_line, marketing_campaign, campaign_send,
         supplier, supply, dish_allergen, dish_price_history
         RESTART IDENTITY CASCADE;

-- Helper: runs a statement and checks that it fails (optionally with a given message).
CREATE FUNCTION pg_temp.must_fail(p_test TEXT, p_sql TEXT, p_text TEXT DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE p_sql;
    EXCEPTION WHEN OTHERS THEN
        IF p_text IS NOT NULL AND position(p_text IN SQLERRM) = 0 THEN
            RAISE EXCEPTION 'FAILED %: it failed, but with another message: %', p_test, SQLERRM;
        END IF;
        RAISE NOTICE 'OK    %  (rejected: %)', p_test, left(SQLERRM, 80);
        RETURN;
    END;
    RAISE EXCEPTION 'FAILED %: the statement should have been rejected', p_test;
END $$;

CREATE FUNCTION pg_temp.must_hold(p_test TEXT, p_cond BOOLEAN) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF p_cond IS TRUE THEN RAISE NOTICE 'OK    %', p_test;
    ELSE RAISE EXCEPTION 'FAILED %', p_test; END IF;
END $$;

-- ---- Minimal data -----------------------------------------------------------
INSERT INTO restaurant (name, address, city) VALUES
  ('Almi Deusto','Lehendakari Aguirre 1','Bilbao'),
  ('Almi Centro','Gran Via 10','Bilbao');
INSERT INTO employee (national_id, first_name, last_name, job, restaurant_id) VALUES
  ('11111111A','Ana','Ruiz','waiter',1),
  ('22222222B','Beto','Gil','waiter',2);
INSERT INTO device_model (device_type, brand, model) VALUES
  ('pos','Brand','POS-15'), ('receipt_printer','Brand','Prn-80'), ('office','Brand','Office-PC');
INSERT INTO device (model_id, restaurant_id, ip) VALUES
  (1,1,'10.0.0.11'),   -- 1: POS, restaurant 1
  (1,2,'10.0.0.11'),   -- 2: POS, restaurant 2 (same IP at another restaurant: allowed)
  (3,1,'10.0.0.5'),    -- 3: office PC, restaurant 1
  (2,1,'10.0.0.21');   -- 4: printer, restaurant 1
INSERT INTO dish (name, category, price, vat_rate) VALUES
  ('Pintxo','starter',3.00,10), ('Beer','drink',2.50,21);
INSERT INTO ingredient (name, unit) VALUES ('Bread','unit');
INSERT INTO recipe VALUES (1,1,2);
INSERT INTO stock VALUES (1,1,5,1);

-- ---- Column constraints -----------------------------------------------------
SELECT pg_temp.must_fail('duplicate national ID', $$INSERT INTO employee (national_id,first_name,last_name,job,restaurant_id) VALUES ('11111111A','X','Y','other',1)$$, 'uk_employee_national_id');
SELECT pg_temp.must_fail('job not in the list', $$INSERT INTO employee (national_id,first_name,last_name,job,restaurant_id) VALUES ('33333333C','X','Y','chef',1)$$);
SELECT pg_temp.must_fail('7 % VAT', $$INSERT INTO dish (name,category,price,vat_rate) VALUES ('Odd','main',5,7)$$);
SELECT pg_temp.must_fail('negative price', $$INSERT INTO dish (name,category,price,vat_rate) VALUES ('Neg','main',-1,10)$$);
SELECT pg_temp.must_fail('marketing without email', $$INSERT INTO customer (name,accepts_marketing) VALUES ('No mail',true)$$, 'ck_customer_marketing_email');
SELECT pg_temp.must_fail('latitude out of range', $$INSERT INTO restaurant (name,address,city,latitude) VALUES ('X','Y','Z',95)$$);
SELECT pg_temp.must_fail('repeated IP at the same restaurant', $$INSERT INTO device (model_id,restaurant_id,ip) VALUES (1,1,'10.0.0.11')$$, 'uk_device_ip');
SELECT pg_temp.must_fail('campaign ends before it starts', $$INSERT INTO marketing_campaign (name,channel,start_date,end_date) VALUES ('C','email','2026-12-01','2026-11-01')$$);
SELECT pg_temp.must_fail('delete a restaurant with employees (RESTRICT)', $$DELETE FROM restaurant WHERE restaurant_id = 1$$);

-- ---- R-03: printer and POS --------------------------------------------------
UPDATE device SET pos_device_id = 1 WHERE device_id = 4;  -- valid
SELECT pg_temp.must_fail('R-03 POS with pos_device_id', $$UPDATE device SET pos_device_id = 1 WHERE device_id = 2$$, 'R-03');
SELECT pg_temp.must_fail('R-03 printer connected to an office PC', $$UPDATE device SET pos_device_id = 3 WHERE device_id = 4$$, 'R-03');
SELECT pg_temp.must_fail('R-03 printer connected to another restaurant''s POS', $$UPDATE device SET pos_device_id = 2 WHERE device_id = 4$$, 'R-03');

-- ---- Invoices: R-01, R-02, R-05 ---------------------------------------------
SELECT pg_temp.must_fail('R-02 invoice from an office PC', $$INSERT INTO invoice (series,payment_method,employee_id,device_id) VALUES ('A','cash',1,3)$$, 'R-02');
SELECT pg_temp.must_fail('R-01 employee from another restaurant', $$INSERT INTO invoice (series,payment_method,employee_id,device_id) VALUES ('A','cash',2,1)$$, 'R-01');
INSERT INTO invoice (series,payment_method,employee_id,device_id) VALUES ('A','cash',1,1);          -- automatic number = 1
INSERT INTO invoice (series,number,payment_method,employee_id,device_id) VALUES ('A',2,'card',1,1); -- explicit, consecutive
SELECT pg_temp.must_hold('R-05 automatic numbering starts at 1', (SELECT number FROM invoice WHERE series='A' ORDER BY invoice_id LIMIT 1) = 1);
SELECT pg_temp.must_fail('R-05 gap in the numbering', $$INSERT INTO invoice (series,number,payment_method,employee_id,device_id) VALUES ('A',9,'cash',1,1)$$, 'R-05');
SELECT pg_temp.must_fail('R-05 repeated number', $$INSERT INTO invoice (series,number,payment_method,employee_id,device_id) VALUES ('A',2,'cash',1,1)$$, 'R-05');
INSERT INTO invoice (series,payment_method,employee_id,device_id) VALUES ('B','other',1,1);
SELECT pg_temp.must_hold('R-05 each series has its own count', (SELECT number FROM invoice WHERE series='B') = 1);

-- ---- Lines, view and R-06 ---------------------------------------------------
INSERT INTO invoice_line VALUES ((SELECT invoice_id FROM invoice WHERE series='A' AND number=1),1,1,2,3.00,10);   -- 2 pintxos -> deducts 2 x 2 = 4 bread
INSERT INTO invoice_line VALUES ((SELECT invoice_id FROM invoice WHERE series='A' AND number=1),2,2,1,2.50,21);   -- 1 beer (no recipe)
SELECT pg_temp.must_hold('R-06 stock deducted (5 - 4 = 1)', (SELECT quantity FROM stock WHERE restaurant_id=1 AND ingredient_id=1) = 1);
SELECT pg_temp.must_hold('View: tax base = 8.50', (SELECT tax_base FROM v_invoice_totals WHERE series='A' AND number=1) = 8.50);
SELECT pg_temp.must_hold('View: VAT = 0.60 + 0.525 -> 1.13', (SELECT vat FROM v_invoice_totals WHERE series='A' AND number=1) = 1.13);
SELECT pg_temp.must_hold('View: total = 9.63', (SELECT total FROM v_invoice_totals WHERE series='A' AND number=1) = 9.63);
SELECT pg_temp.must_hold('View: an invoice without lines is 0', (SELECT total FROM v_invoice_totals WHERE series='A' AND number=2) = 0);
SELECT pg_temp.must_fail('R-06 sale without enough stock', $$INSERT INTO invoice_line SELECT invoice_id,1,1,2,3.00,10 FROM invoice WHERE series='A' AND number=2$$);
SELECT pg_temp.must_fail('line with quantity 0', $$INSERT INTO invoice_line SELECT invoice_id,1,2,0,2.50,21 FROM invoice WHERE series='A' AND number=2$$);
SELECT pg_temp.must_fail('a dish that was sold cannot be deleted (RESTRICT)', $$DELETE FROM dish WHERE dish_id = 1$$);

-- ---- Multivalued attribute, ternary relationship and history (R-07) ----------
INSERT INTO dish_allergen VALUES (1,'gluten'), (1,'fish');
SELECT pg_temp.must_fail('allergen not among the 14', $$INSERT INTO dish_allergen VALUES (2,'chocolate')$$);
SELECT pg_temp.must_fail('same allergen twice on a dish', $$INSERT INTO dish_allergen VALUES (1,'gluten')$$);

INSERT INTO supplier (tax_id, name) VALUES ('B11111111','Bakery One'), ('B22222222','Bakery Two');
INSERT INTO supply VALUES (1,1,1,0.40), (1,1,2,0.45), (2,1,1,0.38);
SELECT pg_temp.must_hold('ternary: same supplier and ingredient, another price at another restaurant', (SELECT count(DISTINCT purchase_price) FROM supply WHERE supplier_id=1 AND ingredient_id=1) = 2);
SELECT pg_temp.must_hold('ternary: restaurant 1 buys bread from two suppliers', (SELECT count(*) FROM supply WHERE ingredient_id=1 AND restaurant_id=1) = 2);
SELECT pg_temp.must_fail('ternary: same triple twice', $$INSERT INTO supply VALUES (1,1,1,0.50)$$);
SELECT pg_temp.must_fail('ternary: purchase price 0', $$INSERT INTO supply VALUES (2,1,2,0)$$);
SELECT pg_temp.must_fail('supplier with a repeated tax ID', $$INSERT INTO supplier (tax_id, name) VALUES ('B11111111','Another')$$, 'uk_supplier_tax_id');

SELECT pg_temp.must_hold('R-07 creating the dish opens its first period', (SELECT count(*) FROM dish_price_history WHERE dish_id=1 AND valid_to IS NULL AND price=3.00) = 1);
UPDATE dish SET price = 3.20 WHERE dish_id = 1;
SELECT pg_temp.must_hold('R-07 raising the price closes one period and opens another', (SELECT count(*) FROM dish_price_history WHERE dish_id=1) = 2 AND (SELECT price FROM dish_price_history WHERE dish_id=1 AND valid_to IS NULL) = 3.20);
UPDATE dish SET description = 'With bread' WHERE dish_id = 1;
SELECT pg_temp.must_hold('R-07 changing the description opens no period', (SELECT count(*) FROM dish_price_history WHERE dish_id=1) = 2);
SELECT pg_temp.must_hold('R-07 a line already sold keeps its price (3.00)', (SELECT unit_price FROM invoice_line WHERE dish_id=1 AND line_no=1) = 3.00);
SELECT pg_temp.must_fail('history: two open periods', $$INSERT INTO dish_price_history (dish_id,valid_from,price,vat_rate) VALUES (1,'2020-01-01',1,10)$$, 'ux_history_open');
SELECT pg_temp.must_fail('history: ends before it starts', $$INSERT INTO dish_price_history VALUES (1,'2020-01-02','2020-01-01',1,10)$$, 'ck_history_dates');

-- ---- R-04: privileges of the application role -------------------------------
SET LOCAL ROLE app_role;
SELECT pg_temp.must_fail('app role cannot write to the history', $$INSERT INTO dish_price_history VALUES (2,'2020-01-01',NULL,1,10)$$, 'permission denied');
SELECT pg_temp.must_fail('app role cannot fix the history', $$UPDATE dish_price_history SET price = 0$$, 'permission denied');
UPDATE dish SET price = 2.80 WHERE dish_id = 2;   -- it can change the price; R-07 records the period
SELECT pg_temp.must_hold('app role changes the price and R-07 records it', (SELECT price FROM dish_price_history WHERE dish_id=2 AND valid_to IS NULL) = 2.80);
SELECT pg_temp.must_fail('R-04 UPDATE on INVOICE', $$UPDATE invoice SET payment_method='other' WHERE series='A' AND number=1$$, 'permission denied');
SELECT pg_temp.must_fail('R-04 DELETE on INVOICE', $$DELETE FROM invoice WHERE series='A' AND number=1$$, 'permission denied');
SELECT pg_temp.must_fail('R-04 UPDATE on INVOICE_LINE', $$UPDATE invoice_line SET quantity=9$$, 'permission denied');
SELECT pg_temp.must_fail('R-04 DELETE on INVOICE_LINE', $$DELETE FROM invoice_line$$, 'permission denied');
SELECT pg_temp.must_fail('app role cannot create devices', $$INSERT INTO device (model_id,restaurant_id) VALUES (1,1)$$, 'permission denied');
INSERT INTO invoice (series,payment_method,employee_id,device_id) VALUES ('C','cash',1,1);  -- it can issue
SELECT pg_temp.must_hold('app role can issue invoices', (SELECT COUNT(*) FROM invoice WHERE series='C') = 1);
RESET ROLE;

SET LOCAL ROLE read_role;
SELECT pg_temp.must_fail('read role cannot insert', $$INSERT INTO customer (name) VALUES ('X')$$, 'permission denied');
RESET ROLE;

ROLLBACK;

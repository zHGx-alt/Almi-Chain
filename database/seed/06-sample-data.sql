-- =============================================================================
-- Almi-Chain · 06: sample data
-- A consistent example of the chain: 2 restaurants, their staff, their devices,
-- the menu with allergens, the store room, suppliers with per-restaurant prices
-- (ternary relationship), customers, a campaign, sales and a later price rise.
-- Sales are plain INSERTs: the triggers in 02-rules.sql number the invoices (R-05),
-- check POS and employee (R-01, R-02) and deduct the stock (R-06).
--
-- Requires 01, 02 and 03 on an EMPTY database:
--   psql -d almi_chain -v ON_ERROR_STOP=1 -f 06-sample-data.sql
-- If the database already has data, the script stops without touching anything.
-- All data is made up (people, tax IDs, phone numbers and emails).
-- Dish names are proper names of Basque dishes and stay as they are.
-- =============================================================================

BEGIN;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM restaurant) THEN
        RAISE EXCEPTION 'The database already has data: 06-sample-data.sql only loads into an empty one';
    END IF;
END $$;

-- ---- Restaurants --------------------------------------------------------------
-- One central database for the whole chain, rows separated by restaurant_id.
INSERT INTO restaurant (name, address, city, phone, latitude, longitude) VALUES
  ('Almi-Chain Abando', 'Example Street 1',  'Bilbao', '944000001', 43.263000, -2.935000),
  ('Almi-Chain Deusto', 'Example Street 25', 'Bilbao', '944000002', 43.271000, -2.946000);

-- ---- Staff ---------------------------------------------------------------------
INSERT INTO employee (national_id, first_name, last_name, job, email, hire_date, restaurant_id)
SELECT v.national_id, v.first_name, v.last_name, v.job, v.email, v.hired::date, r.restaurant_id
FROM (VALUES
  ('00000001R', 'Nerea',  'Etxeberria Ruiz', 'manager', 'manager.abando@example.test', '2026-01-07', 'Almi-Chain Abando'),
  ('00000002W', 'Jon',    'Agirre Sanz',     'bar',     NULL,                          '2026-02-02', 'Almi-Chain Abando'),
  ('00000003A', 'Ane',    'Lopez Uribe',     'waiter',  NULL,                          '2026-03-16', 'Almi-Chain Abando'),
  ('00000004G', 'Mikel',  'Garcia Ortiz',    'kitchen', NULL,                          '2026-01-07', 'Almi-Chain Abando'),
  ('00000005M', 'Leire',  'Zubizarreta Gil', 'manager', 'manager.deusto@example.test', '2026-04-01', 'Almi-Chain Deusto'),
  ('00000006Y', 'Unai',   'Martin Bilbao',   'bar',     NULL,                          '2026-04-01', 'Almi-Chain Deusto')
) AS v(national_id, first_name, last_name, job, email, hired, restaurant)
JOIN restaurant r ON r.name = v.restaurant;

-- ---- Devices (the models chosen in the hardware budget) -----------------------
INSERT INTO device_model (device_type, brand, model) VALUES
  ('office',          'Lenovo',  'ThinkCentre Neo 50q Gen 4'),
  ('pos',             'Iggual',  'AIO B156.88.N100'),
  ('receipt_printer', 'Epson',   'TM-T20IV'),
  ('arcade',          'Generic', '1-core 1 GB PC');

-- IPs from the addressing plan. Printers are on USB and the arcade machine is on
-- the guest Wi-Fi: no fixed IP.
INSERT INTO device (model_id, restaurant_id, operating_system, ip, location, price)
SELECT m.model_id, r.restaurant_id, v.os, v.ip, v.location, v.price
FROM (VALUES
  ('ThinkCentre Neo 50q Gen 4', 'Almi-Chain Abando', 'Windows 10 Pro + Ubuntu LTS', '192.168.10.20', 'Office',      792.67),
  ('AIO B156.88.N100',          'Almi-Chain Abando', 'Windows 10',                  '192.168.10.31', 'Bar',         538.99),
  ('AIO B156.88.N100',          'Almi-Chain Abando', 'Windows 10',                  '192.168.10.32', 'Bar',         538.99),
  ('1-core 1 GB PC',            'Almi-Chain Abando', 'Debian 13 + MAME 0.276',      NULL,            'Dining room', NULL),
  ('AIO B156.88.N100',          'Almi-Chain Deusto', 'Windows 10',                  '192.168.10.31', 'Bar',         538.99)
) AS v(model, restaurant, os, ip, location, price)
JOIN device_model m ON m.model = v.model
JOIN restaurant r ON r.name = v.restaurant;

-- One printer per POS, connected by USB to that POS (R-03).
INSERT INTO device (model_id, restaurant_id, operating_system, ip, location, price, pos_device_id)
SELECT m.model_id, t.restaurant_id, NULL, NULL, 'Bar (USB to POS ' || t.ip || ')', 199.86, t.device_id
FROM device t
JOIN device_model mt ON mt.model_id = t.model_id AND mt.device_type = 'pos'
CROSS JOIN device_model m
WHERE m.model = 'TM-T20IV';

-- ---- Menu (price before VAT; restaurant food in Spain carries 10 % VAT) -------
INSERT INTO dish (name, description, category, price, vat_rate, is_featured) VALUES
  ('Gilda',                 'Pintxo of chilli pepper, anchovy and olive',  'starter',  2.27, 10, FALSE),
  ('Croquetas de jamón',    '6 ham croquettes',                            'starter',  7.27, 10, TRUE),
  ('Bacalao al pil-pil',    'Cod loin in its own emulsion',                'main',    19.09, 10, TRUE),
  ('Txuleta a la brasa',    'Grilled beef chop for two, 1 kg',             'main',    45.45, 10, TRUE),
  ('Marmitako',             'Tuna and potato stew',                        'main',    13.64, 10, FALSE),
  ('Pimientos de Gernika',  'Fried green peppers with flaked salt (new dish, no sales yet)', 'starter', 6.36, 10, FALSE),
  ('Tarta de queso',        'Baked, creamy cheesecake',                    'dessert',  5.91, 10, TRUE),
  ('Pantxineta',            'Puff pastry with custard and almonds',        'dessert',  5.45, 10, FALSE),
  ('Caña',                  'Draught beer',                                'drink',    2.27, 10, FALSE),
  ('Txakoli (copa)',        'Glass of Getariako Txakolina white wine',     'drink',    3.18, 10, FALSE),
  ('Agua mineral',          'Still water, 50 cl',                          'drink',    1.82, 10, FALSE),
  ('Café',                  'Espresso or with milk',                       'drink',    1.45, 10, FALSE);

-- The menu is valid from 1 Jan 2026: R-07 opened each period at load time, and here
-- the real date is set (done by the owner, not by the application).
UPDATE dish_price_history SET valid_from = '2026-01-01 00:00';

-- Allergens (multivalued attribute). Dishes with no rows have none.
INSERT INTO dish_allergen (dish_id, allergen)
SELECT d.dish_id, v.allergen
FROM (VALUES
  ('Gilda', 'fish'), ('Gilda', 'sulphites'),
  ('Croquetas de jamón', 'gluten'), ('Croquetas de jamón', 'dairy'), ('Croquetas de jamón', 'eggs'),
  ('Bacalao al pil-pil', 'fish'),
  ('Marmitako', 'fish'),
  ('Tarta de queso', 'dairy'), ('Tarta de queso', 'eggs'), ('Tarta de queso', 'gluten'),
  ('Pantxineta', 'gluten'), ('Pantxineta', 'dairy'), ('Pantxineta', 'eggs'), ('Pantxineta', 'tree_nuts'),
  ('Caña', 'gluten'),
  ('Txakoli (copa)', 'sulphites')
) AS v(dish, allergen)
JOIN dish d ON d.name = v.dish;

-- ---- Store room ------------------------------------------------------------------
INSERT INTO ingredient (name, unit) VALUES
  ('Anchovy', 'unit'), ('Chilli pepper', 'unit'), ('Olive', 'unit'),
  ('Croquette dough', 'kg'), ('Cod', 'kg'), ('Olive oil', 'l'),
  ('Beef chop', 'kg'), ('Bonito tuna', 'kg'), ('Potato', 'kg'),
  ('Cream cheese', 'kg'), ('Draught beer', 'l'), ('Txakoli', 'l'), ('Coffee beans', 'kg');

-- Quantity per serving of each dish (R-06 deducts it on every sale).
INSERT INTO recipe (dish_id, ingredient_id, quantity)
SELECT d.dish_id, i.ingredient_id, v.quantity
FROM (VALUES
  ('Gilda', 'Anchovy', 1), ('Gilda', 'Chilli pepper', 2), ('Gilda', 'Olive', 1),
  ('Croquetas de jamón', 'Croquette dough', 0.180),
  ('Bacalao al pil-pil', 'Cod', 0.250), ('Bacalao al pil-pil', 'Olive oil', 0.100),
  ('Txuleta a la brasa', 'Beef chop', 1.000),
  ('Marmitako', 'Bonito tuna', 0.200), ('Marmitako', 'Potato', 0.250),
  ('Tarta de queso', 'Cream cheese', 0.120),
  ('Caña', 'Draught beer', 0.200),
  ('Txakoli (copa)', 'Txakoli', 0.120),
  ('Café', 'Coffee beans', 0.008)
) AS v(dish, ingredient, quantity)
JOIN dish d ON d.name = v.dish
JOIN ingredient i ON i.name = v.ingredient;

-- Opening stock of each restaurant. Abando's beef chop is left tight on purpose:
-- after the sales it drops below the minimum (query Q-08 in 07-queries.sql).
INSERT INTO stock (restaurant_id, ingredient_id, quantity, min_quantity)
SELECT r.restaurant_id, i.ingredient_id, v.quantity, v.minimum
FROM (VALUES
  ('Almi-Chain Abando', 'Anchovy', 120, 30), ('Almi-Chain Abando', 'Chilli pepper', 200, 50),
  ('Almi-Chain Abando', 'Olive', 200, 50), ('Almi-Chain Abando', 'Croquette dough', 5, 1),
  ('Almi-Chain Abando', 'Cod', 6, 2), ('Almi-Chain Abando', 'Olive oil', 20, 5),
  ('Almi-Chain Abando', 'Beef chop', 4, 3), ('Almi-Chain Abando', 'Bonito tuna', 5, 1),
  ('Almi-Chain Abando', 'Potato', 25, 5), ('Almi-Chain Abando', 'Cream cheese', 4, 1),
  ('Almi-Chain Abando', 'Draught beer', 50, 10), ('Almi-Chain Abando', 'Txakoli', 12, 3),
  ('Almi-Chain Abando', 'Coffee beans', 3, 1),
  ('Almi-Chain Deusto', 'Anchovy', 80, 30), ('Almi-Chain Deusto', 'Chilli pepper', 150, 50),
  ('Almi-Chain Deusto', 'Olive', 150, 50), ('Almi-Chain Deusto', 'Croquette dough', 3, 1),
  ('Almi-Chain Deusto', 'Draught beer', 30, 10), ('Almi-Chain Deusto', 'Coffee beans', 2, 1)
) AS v(restaurant, ingredient, quantity, minimum)
JOIN restaurant r ON r.name = v.restaurant
JOIN ingredient i ON i.name = v.ingredient;

-- ---- Suppliers ------------------------------------------------------------------
INSERT INTO supplier (tax_id, name, phone, email) VALUES
  ('B00000011', 'Example Meats Ltd',      '944000201', 'orders@meats.example.test'),
  ('B00000012', 'Example Fish Ltd',       '944000202', 'orders@fish.example.test'),
  ('B00000013', 'Example Distribution',   '944000203', 'orders@distribution.example.test'),
  ('B00000014', 'Example Wholesale Inc',  '944000204', 'orders@wholesale.example.test');

-- Ternary relationship: which supplier delivers which ingredient to which restaurant
-- and at what price (per ingredient unit). Beer and coffee are bought from two
-- suppliers at Abando; the beef chop costs differently at each restaurant.
INSERT INTO supply (supplier_id, ingredient_id, restaurant_id, purchase_price)
SELECT s.supplier_id, i.ingredient_id, r.restaurant_id, v.price
FROM (VALUES
  ('Example Meats Ltd',     'Beef chop',       'Almi-Chain Abando', 24.50),
  ('Example Meats Ltd',     'Beef chop',       'Almi-Chain Deusto', 25.90),
  ('Example Meats Ltd',     'Croquette dough', 'Almi-Chain Abando',  9.80),
  ('Example Meats Ltd',     'Croquette dough', 'Almi-Chain Deusto',  9.80),
  ('Example Fish Ltd',      'Cod',             'Almi-Chain Abando', 18.00),
  ('Example Fish Ltd',      'Bonito tuna',     'Almi-Chain Abando', 14.50),
  ('Example Fish Ltd',      'Anchovy',         'Almi-Chain Abando',  0.35),
  ('Example Fish Ltd',      'Anchovy',         'Almi-Chain Deusto',  0.38),
  ('Example Distribution',  'Draught beer',    'Almi-Chain Abando',  2.10),
  ('Example Distribution',  'Draught beer',    'Almi-Chain Deusto',  2.10),
  ('Example Wholesale Inc', 'Draught beer',    'Almi-Chain Abando',  2.25),
  ('Example Distribution',  'Coffee beans',    'Almi-Chain Abando', 16.00),
  ('Example Wholesale Inc', 'Coffee beans',    'Almi-Chain Abando', 15.40),
  ('Example Distribution',  'Coffee beans',    'Almi-Chain Deusto', 16.00),
  ('Example Distribution',  'Txakoli',         'Almi-Chain Abando',  7.20)
) AS v(supplier, ingredient, restaurant, price)
JOIN supplier s   ON s.name = v.supplier
JOIN ingredient i ON i.name = v.ingredient
JOIN restaurant r ON r.name = v.restaurant;

-- ---- Customers and marketing ----------------------------------------------------
INSERT INTO customer (tax_id, name, email, phone, accepts_marketing) VALUES
  ('B00000001', 'Example Events Ltd',  'bookings@events.example.test', '944000100', TRUE),
  (NULL,        'Maite Example',       'maite@example.test',           NULL,        TRUE),
  (NULL,        'Iñaki Example',       'inaki@example.test',           NULL,        FALSE),
  ('00000007F', 'Koldo Example',       NULL,                           '600000001', FALSE);

INSERT INTO marketing_campaign (name, channel, start_date, end_date) VALUES
  ('Autumn menu 2026', 'email',  '2026-10-01', '2026-11-30'),
  ('New txakoli',      'social', '2026-11-01', NULL);

-- The autumn campaign can only reach customers who accept marketing (and have an
-- email, enforced by the CHECK).
INSERT INTO campaign_send (campaign_id, customer_id, sent_at)
SELECT c.campaign_id, cu.customer_id, '2026-10-01 10:00'
FROM marketing_campaign c
JOIN customer cu ON cu.accepts_marketing AND cu.name = 'Maite Example'
WHERE c.name = 'Autumn menu 2026';

-- ---- Sales ------------------------------------------------------------------------
-- pg_temp.sale: one invoice with its lines, the way the POS would do it.
-- Each line copies the dish's price and VAT rate at the time of sale.
CREATE FUNCTION pg_temp.sale(p_series TEXT, p_restaurant TEXT, p_pos_ip TEXT, p_national_id TEXT,
                             p_customer TEXT, p_payment TEXT, p_at TIMESTAMP,
                             p_dishes TEXT[], p_quantities INTEGER[]) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_invoice INTEGER;
BEGIN
    INSERT INTO invoice (series, issued_at, payment_method, customer_id, employee_id, device_id)
    VALUES (p_series, p_at, p_payment,
            (SELECT customer_id FROM customer WHERE name = p_customer),
            (SELECT employee_id FROM employee WHERE national_id = p_national_id),
            (SELECT d.device_id FROM device d
               JOIN restaurant r ON r.restaurant_id = d.restaurant_id
              WHERE r.name = p_restaurant AND d.ip = p_pos_ip))
    RETURNING invoice_id INTO v_invoice;

    INSERT INTO invoice_line (invoice_id, line_no, dish_id, quantity, unit_price, vat_rate)
    SELECT v_invoice, l.n, d.dish_id, p_quantities[l.n], d.price, d.vat_rate
    FROM generate_subscripts(p_dishes, 1) AS l(n)
    JOIN dish d ON d.name = p_dishes[l.n];
END $$;

-- Abando, POS 1 (series A1) and POS 2 (series A2); Deusto, POS 1 (series D1).
DO $$
BEGIN
PERFORM pg_temp.sale('A1', 'Almi-Chain Abando', '192.168.10.31', '00000002W', NULL, 'cash', '2026-10-19 13:40',
       ARRAY['Gilda','Caña','Café'], ARRAY[4,4,2]);
PERFORM pg_temp.sale('A1', 'Almi-Chain Abando', '192.168.10.31', '00000002W', NULL, 'card', '2026-10-19 14:25',
       ARRAY['Croquetas de jamón','Bacalao al pil-pil','Tarta de queso','Agua mineral'], ARRAY[1,2,2,2]);
PERFORM pg_temp.sale('A2', 'Almi-Chain Abando', '192.168.10.32', '00000003A', 'Example Events Ltd', 'card', '2026-10-19 15:10',
       ARRAY['Txuleta a la brasa','Marmitako','Txakoli (copa)','Pantxineta','Café'], ARRAY[1,2,4,2,4]);
PERFORM pg_temp.sale('A1', 'Almi-Chain Abando', '192.168.10.31', '00000003A', 'Maite Example', 'cash', '2026-10-20 21:05',
       ARRAY['Txuleta a la brasa','Tarta de queso','Txakoli (copa)'], ARRAY[1,1,2]);
PERFORM pg_temp.sale('A2', 'Almi-Chain Abando', '192.168.10.32', '00000002W', NULL, 'card', '2026-10-20 21:40',
       ARRAY['Gilda','Croquetas de jamón','Caña'], ARRAY[2,1,3]);
PERFORM pg_temp.sale('A1', 'Almi-Chain Abando', '192.168.10.31', '00000002W', 'Koldo Example', 'card', '2026-10-21 14:00',
       ARRAY['Bacalao al pil-pil','Txuleta a la brasa','Agua mineral'], ARRAY[1,1,1]);
PERFORM pg_temp.sale('D1', 'Almi-Chain Deusto', '192.168.10.31', '00000006Y', NULL, 'cash', '2026-10-20 12:30',
       ARRAY['Gilda','Caña','Café'], ARRAY[6,5,3]);
PERFORM pg_temp.sale('D1', 'Almi-Chain Deusto', '192.168.10.31', '00000006Y', 'Iñaki Example', 'card', '2026-10-21 13:15',
       ARRAY['Croquetas de jamón','Caña'], ARRAY[2,2]);
END $$;

-- After the sales the coffee goes up (R-07 closes the 1.45 period and opens 1.55).
-- Invoices already issued keep the price of their day (query Q-15).
UPDATE dish SET price = 1.55 WHERE name = 'Café';

COMMIT;

-- Summary of what was loaded
SELECT 'restaurant' AS table_name, count(*) AS row_count FROM restaurant
UNION ALL SELECT 'employee', count(*) FROM employee
UNION ALL SELECT 'device_model', count(*) FROM device_model
UNION ALL SELECT 'device', count(*) FROM device
UNION ALL SELECT 'dish', count(*) FROM dish
UNION ALL SELECT 'ingredient', count(*) FROM ingredient
UNION ALL SELECT 'stock', count(*) FROM stock
UNION ALL SELECT 'recipe', count(*) FROM recipe
UNION ALL SELECT 'customer', count(*) FROM customer
UNION ALL SELECT 'marketing_campaign', count(*) FROM marketing_campaign
UNION ALL SELECT 'campaign_send', count(*) FROM campaign_send
UNION ALL SELECT 'invoice', count(*) FROM invoice
UNION ALL SELECT 'invoice_line', count(*) FROM invoice_line
UNION ALL SELECT 'dish_allergen', count(*) FROM dish_allergen
UNION ALL SELECT 'dish_price_history', count(*) FROM dish_price_history
UNION ALL SELECT 'supplier', count(*) FROM supplier
UNION ALL SELECT 'supply', count(*) FROM supply;

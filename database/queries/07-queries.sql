-- =============================================================================
-- Almi-Chain · 07: business questions on the sample data
-- Read-only: can run as a member of read_role.
--   psql -d almi_chain -f 07-queries.sql
-- Each query has a code (Q-01...) and the technique it uses.
-- =============================================================================

\echo '== Q-01 Menu with the customer price (VAT included) · SELECT with expressions and ORDER BY'
SELECT category, name, price AS base,
       round(price * (1 + vat_rate / 100), 2) AS customer_price,
       CASE WHEN is_featured THEN 'yes' ELSE '' END AS featured
FROM dish
ORDER BY CASE category WHEN 'starter' THEN 1 WHEN 'main' THEN 2
                       WHEN 'dessert' THEN 3 ELSE 4 END, name;

\echo '== Q-02 Invoices with restaurant, POS, employee, customer and total · 5-table JOIN and view'
SELECT i.series || '-' || i.number AS invoice,
       to_char(i.issued_at, 'DD/MM HH24:MI') AS issued,
       r.name AS restaurant, d.ip AS pos,
       e.first_name AS employee,
       COALESCE(c.name, '(simplified receipt)') AS customer,
       i.payment_method, t.total
FROM invoice i
JOIN device d           ON d.device_id = i.device_id
JOIN restaurant r       ON r.restaurant_id = d.restaurant_id
JOIN employee e         ON e.employee_id = i.employee_id
LEFT JOIN customer c    ON c.customer_id = i.customer_id
JOIN v_invoice_totals t ON t.invoice_id = i.invoice_id
ORDER BY i.issued_at;

\echo '== Q-03 Sales by restaurant and day · GROUP BY with SUM and COUNT'
SELECT r.name AS restaurant, i.issued_at::date AS day,
       count(*) AS invoices, sum(t.tax_base) AS tax_base, sum(t.vat) AS vat, sum(t.total) AS total
FROM invoice i
JOIN device d           ON d.device_id = i.device_id
JOIN restaurant r       ON r.restaurant_id = d.restaurant_id
JOIN v_invoice_totals t ON t.invoice_id = i.invoice_id
GROUP BY r.name, i.issued_at::date
ORDER BY restaurant, day;

\echo '== Q-04 Top 5 dishes across the chain · JOIN, GROUP BY, ORDER BY and LIMIT'
SELECT d.name, d.category, sum(l.quantity) AS units,
       sum(l.quantity * l.unit_price) AS net_sales
FROM invoice_line l
JOIN dish d ON d.dish_id = l.dish_id
GROUP BY d.dish_id, d.name, d.category
ORDER BY units DESC, net_sales DESC
LIMIT 5;

\echo '== Q-05 Dishes never sold · NOT EXISTS subquery'
SELECT d.name, d.category
FROM dish d
WHERE NOT EXISTS (SELECT 1 FROM invoice_line l WHERE l.dish_id = d.dish_id)
ORDER BY d.name;

\echo '== Q-06 Invoices above the average amount · scalar subquery'
SELECT t.series || '-' || t.number AS invoice, t.total,
       (SELECT round(avg(total), 2) FROM v_invoice_totals) AS average
FROM v_invoice_totals t
WHERE t.total > (SELECT avg(total) FROM v_invoice_totals)
ORDER BY t.total DESC;

\echo '== Q-07 Sales per employee, only those above 100 EUR · GROUP BY with HAVING'
SELECT e.first_name || ' ' || e.last_name AS employee, e.job,
       count(*) AS invoices, sum(t.total) AS total_sold
FROM invoice i
JOIN employee e         ON e.employee_id = i.employee_id
JOIN v_invoice_totals t ON t.invoice_id = i.invoice_id
GROUP BY e.employee_id, e.first_name, e.last_name, e.job
HAVING sum(t.total) > 100
ORDER BY total_sold DESC;

\echo '== Q-08 Ingredients below minimum stock (shopping list) · JOIN and column comparison'
SELECT r.name AS restaurant, i.name AS ingredient, s.quantity, s.min_quantity, i.unit
FROM stock s
JOIN restaurant r ON r.restaurant_id = s.restaurant_id
JOIN ingredient i ON i.ingredient_id = s.ingredient_id
WHERE s.quantity < s.min_quantity
ORDER BY restaurant, ingredient;

\echo '== Q-09 Ingredients consumed by sales, per restaurant · 6-table JOIN through the recipe'
SELECT r.name AS restaurant, ing.name AS ingredient,
       sum(l.quantity * rc.quantity) AS consumed, ing.unit
FROM invoice_line l
JOIN invoice i        ON i.invoice_id = l.invoice_id
JOIN device d         ON d.device_id = i.device_id
JOIN restaurant r     ON r.restaurant_id = d.restaurant_id
JOIN recipe rc        ON rc.dish_id = l.dish_id
JOIN ingredient ing   ON ing.ingredient_id = rc.ingredient_id
GROUP BY r.name, ing.name, ing.unit
ORDER BY restaurant, consumed DESC;

\echo '== Q-10 Customers who accept marketing and have not received the autumn campaign · NOT IN subquery'
SELECT c.name, c.email
FROM customer c
WHERE c.accepts_marketing
  AND c.customer_id NOT IN (SELECT cs.customer_id
                              FROM campaign_send cs
                              JOIN marketing_campaign mc ON mc.campaign_id = cs.campaign_id
                             WHERE mc.name = 'Autumn menu 2026')
ORDER BY c.name;

\echo '== Q-11 Each printer with its POS · self-join (device with itself)'
SELECT r.name AS restaurant, mp.brand || ' ' || mp.model AS printer,
       t.ip AS pos, mt.brand || ' ' || mt.model AS pos_model
FROM device p
JOIN device_model mp ON mp.model_id = p.model_id AND mp.device_type = 'receipt_printer'
JOIN device t        ON t.device_id = p.pos_device_id
JOIN device_model mt ON mt.model_id = t.model_id
JOIN restaurant r    ON r.restaurant_id = p.restaurant_id
ORDER BY restaurant, pos;

\echo '== Q-12 Device inventory and cost per restaurant · LEFT JOIN, GROUP BY and COALESCE'
SELECT r.name AS restaurant, m.device_type, count(d.device_id) AS devices,
       COALESCE(sum(d.price), 0) AS cost
FROM restaurant r
CROSS JOIN (SELECT DISTINCT device_type FROM device_model) types
LEFT JOIN device_model m ON m.device_type = types.device_type
LEFT JOIN device d       ON d.model_id = m.model_id AND d.restaurant_id = r.restaurant_id
GROUP BY r.name, m.device_type
ORDER BY restaurant, m.device_type;

\echo '== Q-13 Gluten-free dishes and their other allergens · multivalued attribute with NOT EXISTS and string_agg'
SELECT d.category, d.name,
       COALESCE(string_agg(a.allergen, ', ' ORDER BY a.allergen), '(none)') AS other_allergens
FROM dish d
LEFT JOIN dish_allergen a ON a.dish_id = d.dish_id
WHERE NOT EXISTS (SELECT 1 FROM dish_allergen g WHERE g.dish_id = d.dish_id AND g.allergen = 'gluten')
GROUP BY d.category, d.name
ORDER BY d.category, d.name;

\echo '== Q-14 Cheapest supplier of each ingredient at each restaurant · ternary relationship with DISTINCT ON'
SELECT DISTINCT ON (r.name, i.name)
       r.name AS restaurant, i.name AS ingredient, s.name AS supplier,
       su.purchase_price || ' EUR/' || i.unit AS price,
       count(*) OVER (PARTITION BY r.name, i.name) AS suppliers
FROM supply su
JOIN supplier s   ON s.supplier_id = su.supplier_id
JOIN ingredient i ON i.ingredient_id = su.ingredient_id
JOIN restaurant r ON r.restaurant_id = su.restaurant_id
ORDER BY r.name, i.name, su.purchase_price;

\echo '== Q-15 Price history: each coffee sale against the price valid that day · history with a date range'
SELECT i.series || '-' || i.number AS invoice, i.issued_at::date AS day,
       l.unit_price AS price_charged, h.price AS price_valid_that_day,
       (SELECT price FROM dish WHERE dish_id = l.dish_id) AS price_today
FROM invoice_line l
JOIN invoice i ON i.invoice_id = l.invoice_id
JOIN dish d    ON d.dish_id = l.dish_id AND d.name = 'Café'
JOIN dish_price_history h ON h.dish_id = l.dish_id
                         AND i.issued_at >= h.valid_from
                         AND (h.valid_to IS NULL OR i.issued_at < h.valid_to)
ORDER BY i.issued_at;

\echo '   Coffee price periods'
SELECT h.valid_from, COALESCE(h.valid_to::text, '(current)') AS valid_to, h.price, h.vat_rate
FROM dish_price_history h JOIN dish d ON d.dish_id = h.dish_id
WHERE d.name = 'Café'
ORDER BY h.valid_from;

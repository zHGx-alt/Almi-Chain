-- =============================================================================
-- Almi-Chain · 01: tables, indexes and view
-- PostgreSQL 12 or later (tested on 17 and 18).
-- Normalised (3NF) model: 17 tables plus the v_invoice_totals view.
--
-- Runs ONCE on the chain's central database:
--   psql -d almi_chain -v ON_ERROR_STOP=1 -f 01-tables.sql
--
-- Assumptions:
--   A-1  Allowed VAT rates: 4, 10 and 21 %.
--   A-2  Employees and dishes are never deactivated (no "active" flag).
--   A-3  Lists of allowed values are CHECK constraints, not lookup tables.
-- =============================================================================

BEGIN;

-- Order: referenced tables first (because of the foreign keys).

CREATE TABLE restaurant (
    restaurant_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name          VARCHAR(100) NOT NULL,
    address       VARCHAR(200) NOT NULL,
    city          VARCHAR(100) NOT NULL,
    phone         VARCHAR(20),
    latitude      NUMERIC(9,6) CHECK (latitude  BETWEEN -90  AND 90),
    longitude     NUMERIC(9,6) CHECK (longitude BETWEEN -180 AND 180),
    CONSTRAINT uk_restaurant_address UNIQUE (address, city)
);

CREATE TABLE employee (
    employee_id   INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    national_id   VARCHAR(9)   NOT NULL,
    first_name    VARCHAR(100) NOT NULL,
    last_name     VARCHAR(150) NOT NULL,
    job           VARCHAR(20)  NOT NULL
                  CHECK (job IN ('manager','waiter','kitchen','bar','other')),
    email         VARCHAR(254),
    phone         VARCHAR(20),
    hire_date     DATE         NOT NULL DEFAULT CURRENT_DATE,
    restaurant_id INTEGER      NOT NULL
                  REFERENCES restaurant (restaurant_id) ON DELETE RESTRICT,
    CONSTRAINT uk_employee_national_id UNIQUE (national_id)
);

CREATE TABLE customer (
    customer_id       INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tax_id            VARCHAR(9),                       -- several NULLs allowed
    name              VARCHAR(150) NOT NULL,
    email             VARCHAR(254),
    phone             VARCHAR(20),
    accepts_marketing BOOLEAN      NOT NULL DEFAULT FALSE,
    CONSTRAINT uk_customer_tax_id UNIQUE (tax_id),
    CONSTRAINT ck_customer_marketing_email
        CHECK (NOT accepts_marketing OR email IS NOT NULL)
);

CREATE TABLE device_model (
    model_id    INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    device_type VARCHAR(20)  NOT NULL
                CHECK (device_type IN ('office','pos','arcade','receipt_printer')),
    brand       VARCHAR(50)  NOT NULL,
    model       VARCHAR(100) NOT NULL,
    CONSTRAINT uk_device_model UNIQUE (brand, model)
);

CREATE TABLE device (
    device_id        INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    model_id         INTEGER NOT NULL
                     REFERENCES device_model (model_id) ON DELETE RESTRICT,
    restaurant_id    INTEGER NOT NULL
                     REFERENCES restaurant (restaurant_id) ON DELETE RESTRICT,
    operating_system VARCHAR(50),
    ip               VARCHAR(45),
    location         VARCHAR(100),
    price            NUMERIC(10,2) CHECK (price >= 0),
    pos_device_id    INTEGER
                     REFERENCES device (device_id) ON DELETE SET NULL,  -- printers only (R-03)
    CONSTRAINT uk_device_ip UNIQUE (restaurant_id, ip),
    CONSTRAINT ck_device_not_self_referencing
        CHECK (pos_device_id IS NULL OR pos_device_id <> device_id)
);

CREATE TABLE dish (
    dish_id     INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name        VARCHAR(100) NOT NULL,
    description VARCHAR(500),
    category    VARCHAR(20)  NOT NULL
                CHECK (category IN ('starter','main','dessert','drink')),
    price       NUMERIC(8,2) NOT NULL CHECK (price >= 0),
    vat_rate    NUMERIC(4,2) NOT NULL CHECK (vat_rate IN (4, 10, 21)),
    is_featured BOOLEAN      NOT NULL DEFAULT FALSE,
    image_url   VARCHAR(255),
    CONSTRAINT uk_dish_name UNIQUE (name)
);

-- Multivalued attribute of DISH: a dish has 0 or more allergens.
-- The 14 allergens that must be declared (EU Regulation 1169/2011, Annex II).
CREATE TABLE dish_allergen (
    dish_id  INTEGER     NOT NULL
             REFERENCES dish (dish_id) ON DELETE CASCADE,
    allergen VARCHAR(20) NOT NULL
             CHECK (allergen IN ('gluten','crustaceans','eggs','fish','peanuts',
                                 'soy','dairy','tree_nuts','celery','mustard',
                                 'sesame','sulphites','lupin','molluscs')),
    PRIMARY KEY (dish_id, allergen)
);

-- Price history of DISH (weak entity): one period per price it has had.
-- The open period (valid_to NULL) is the current price.
-- Written by trigger R-07 in 02-rules.sql; the application can only read it.
CREATE TABLE dish_price_history (
    dish_id    INTEGER      NOT NULL
               REFERENCES dish (dish_id) ON DELETE CASCADE,
    valid_from TIMESTAMP    NOT NULL,
    valid_to   TIMESTAMP,
    price      NUMERIC(8,2) NOT NULL CHECK (price >= 0),
    vat_rate   NUMERIC(4,2) NOT NULL CHECK (vat_rate IN (4, 10, 21)),
    PRIMARY KEY (dish_id, valid_from),
    CONSTRAINT ck_history_dates CHECK (valid_to IS NULL OR valid_to > valid_from)
);
-- Only one open period per dish (partial unique index).
CREATE UNIQUE INDEX ux_history_open ON dish_price_history (dish_id) WHERE valid_to IS NULL;

CREATE TABLE ingredient (
    ingredient_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name          VARCHAR(100) NOT NULL,
    unit          VARCHAR(10)  NOT NULL
                  CHECK (unit IN ('kg','g','l','ml','unit')),
    CONSTRAINT uk_ingredient_name UNIQUE (name)
);

CREATE TABLE supplier (
    supplier_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tax_id      VARCHAR(9)   NOT NULL,
    name        VARCHAR(150) NOT NULL,
    phone       VARCHAR(20),
    email       VARCHAR(254),
    CONSTRAINT uk_supplier_tax_id UNIQUE (tax_id)
);

CREATE TABLE stock (
    restaurant_id INTEGER NOT NULL
                  REFERENCES restaurant (restaurant_id) ON DELETE RESTRICT,
    ingredient_id INTEGER NOT NULL
                  REFERENCES ingredient (ingredient_id) ON DELETE RESTRICT,
    quantity      NUMERIC(10,3) NOT NULL CHECK (quantity >= 0),
    min_quantity  NUMERIC(10,3) NOT NULL DEFAULT 0 CHECK (min_quantity >= 0),
    PRIMARY KEY (restaurant_id, ingredient_id)
);

-- Ternary relationship SUPPLIER-INGREDIENT-RESTAURANT: which supplier delivers which
-- ingredient to which restaurant, and at what price. The key is the three foreign keys:
-- the price depends on all three at once (the same supplier charges each restaurant
-- differently, and a restaurant buys the same ingredient from several suppliers).
CREATE TABLE supply (
    supplier_id    INTEGER NOT NULL
                   REFERENCES supplier (supplier_id) ON DELETE CASCADE,
    ingredient_id  INTEGER NOT NULL
                   REFERENCES ingredient (ingredient_id) ON DELETE RESTRICT,
    restaurant_id  INTEGER NOT NULL
                   REFERENCES restaurant (restaurant_id) ON DELETE RESTRICT,
    purchase_price NUMERIC(10,2) NOT NULL CHECK (purchase_price > 0),  -- per ingredient unit
    PRIMARY KEY (supplier_id, ingredient_id, restaurant_id)
);

CREATE TABLE recipe (
    dish_id       INTEGER NOT NULL
                  REFERENCES dish (dish_id) ON DELETE CASCADE,
    ingredient_id INTEGER NOT NULL
                  REFERENCES ingredient (ingredient_id) ON DELETE RESTRICT,
    quantity      NUMERIC(10,3) NOT NULL CHECK (quantity > 0),
    PRIMARY KEY (dish_id, ingredient_id)
);

CREATE TABLE invoice (
    invoice_id     INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    series         VARCHAR(10) NOT NULL,
    number         INTEGER     NOT NULL CHECK (number > 0),   -- set by the trigger (R-05)
    issued_at      TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    payment_method VARCHAR(20) NOT NULL
                   CHECK (payment_method IN ('cash','card','other')),
    customer_id    INTEGER REFERENCES customer (customer_id) ON DELETE RESTRICT,  -- NULL = simplified receipt
    employee_id    INTEGER NOT NULL REFERENCES employee (employee_id) ON DELETE RESTRICT,
    device_id      INTEGER NOT NULL REFERENCES device   (device_id)   ON DELETE RESTRICT,
    CONSTRAINT uk_invoice_series_number UNIQUE (series, number)
);

CREATE TABLE invoice_line (
    invoice_id INTEGER NOT NULL
               REFERENCES invoice (invoice_id) ON DELETE CASCADE,
    line_no    INTEGER NOT NULL CHECK (line_no > 0),
    dish_id    INTEGER NOT NULL
               REFERENCES dish (dish_id) ON DELETE RESTRICT,
    quantity   INTEGER NOT NULL CHECK (quantity > 0),
    unit_price NUMERIC(8,2) NOT NULL CHECK (unit_price >= 0),          -- price at the time of sale
    vat_rate   NUMERIC(4,2) NOT NULL CHECK (vat_rate IN (4, 10, 21)),  -- rate at the time of sale
    PRIMARY KEY (invoice_id, line_no)
);

CREATE TABLE marketing_campaign (
    campaign_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name        VARCHAR(100) NOT NULL,
    channel     VARCHAR(20)  NOT NULL CHECK (channel IN ('email','sms','social')),
    start_date  DATE         NOT NULL,
    end_date    DATE,
    CONSTRAINT ck_campaign_dates CHECK (end_date IS NULL OR end_date >= start_date)
);

CREATE TABLE campaign_send (
    campaign_id INTEGER NOT NULL
                REFERENCES marketing_campaign (campaign_id) ON DELETE CASCADE,
    customer_id INTEGER NOT NULL
                REFERENCES customer (customer_id) ON DELETE CASCADE,
    sent_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (campaign_id, customer_id)
);

-- Indexes on foreign keys that do not already lead a primary or unique key.
-- (PostgreSQL does not create them by itself; they speed up joins and deletes.)
CREATE INDEX ix_employee_restaurant          ON employee (restaurant_id);
CREATE INDEX ix_device_model                 ON device (model_id);
CREATE INDEX ix_device_pos                   ON device (pos_device_id);
CREATE INDEX ix_stock_ingredient             ON stock (ingredient_id);
CREATE INDEX ix_recipe_ingredient            ON recipe (ingredient_id);
CREATE INDEX ix_invoice_customer             ON invoice (customer_id);
CREATE INDEX ix_invoice_employee             ON invoice (employee_id);
CREATE INDEX ix_invoice_device               ON invoice (device_id);
CREATE INDEX ix_invoice_issued_at            ON invoice (issued_at);
CREATE INDEX ix_line_dish                    ON invoice_line (dish_id);
CREATE INDEX ix_send_customer                ON campaign_send (customer_id);
CREATE INDEX ix_supply_ingredient_restaurant ON supply (ingredient_id, restaurant_id);
CREATE INDEX ix_supply_restaurant            ON supply (restaurant_id);

-- Invoice totals are derived, not stored (avoids redundancy).
CREATE VIEW v_invoice_totals AS
SELECT i.invoice_id,
       i.series,
       i.number,
       COALESCE(SUM(l.quantity * l.unit_price), 0)::NUMERIC(12,2)                    AS tax_base,
       COALESCE(SUM(l.quantity * l.unit_price * l.vat_rate / 100), 0)::NUMERIC(12,2) AS vat,
       (COALESCE(SUM(l.quantity * l.unit_price), 0)
        + COALESCE(SUM(l.quantity * l.unit_price * l.vat_rate / 100), 0))::NUMERIC(12,2) AS total
FROM invoice i
LEFT JOIN invoice_line l ON l.invoice_id = i.invoice_id
GROUP BY i.invoice_id, i.series, i.number;

COMMIT;

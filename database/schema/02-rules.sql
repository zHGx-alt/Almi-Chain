-- =============================================================================
-- Almi-Chain · 02: business rules a foreign key cannot express (triggers)
-- R-01, R-02, R-03, R-05, R-06 and R-07. (R-04 is enforced with privileges in 03-roles.sql.)
-- Requires 01-tables.sql.
-- =============================================================================

BEGIN;

-- R-03: pos_device_id only on receipt printers, and it points to a POS in the same restaurant.
CREATE FUNCTION fn_device_printer_pos() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_own_type          VARCHAR(20);
    v_target_type       VARCHAR(20);
    v_target_restaurant INTEGER;
BEGIN
    IF NEW.pos_device_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT device_type INTO v_own_type FROM device_model WHERE model_id = NEW.model_id;
    IF v_own_type <> 'receipt_printer' THEN
        RAISE EXCEPTION 'R-03: only a receipt printer can have pos_device_id (the device is of type %)', v_own_type;
    END IF;

    SELECT m.device_type, d.restaurant_id
      INTO v_target_type, v_target_restaurant
      FROM device d JOIN device_model m ON m.model_id = d.model_id
     WHERE d.device_id = NEW.pos_device_id;
    IF v_target_type <> 'pos' THEN
        RAISE EXCEPTION 'R-03: the printer must be connected to a pos device (the target is %)', v_target_type;
    END IF;
    IF v_target_restaurant <> NEW.restaurant_id THEN
        RAISE EXCEPTION 'R-03: the printer and its POS must belong to the same restaurant';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER tg_device_printer_pos
BEFORE INSERT OR UPDATE ON device
FOR EACH ROW EXECUTE FUNCTION fn_device_printer_pos();

-- R-01 and R-02: the invoice's device is a POS and the employee works at the same restaurant.
CREATE FUNCTION fn_invoice_consistency() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_type           VARCHAR(20);
    v_pos_restaurant INTEGER;
    v_emp_restaurant INTEGER;
BEGIN
    SELECT m.device_type, d.restaurant_id
      INTO v_type, v_pos_restaurant
      FROM device d JOIN device_model m ON m.model_id = d.model_id
     WHERE d.device_id = NEW.device_id;
    IF v_type <> 'pos' THEN
        RAISE EXCEPTION 'R-02: an invoice must be issued from a pos device (it is %)', v_type;
    END IF;

    SELECT restaurant_id INTO v_emp_restaurant FROM employee WHERE employee_id = NEW.employee_id;
    IF v_emp_restaurant <> v_pos_restaurant THEN
        RAISE EXCEPTION 'R-01: the employee and the POS of an invoice must belong to the same restaurant';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER tg_invoice_consistency
BEFORE INSERT ON invoice
FOR EACH ROW EXECUTE FUNCTION fn_invoice_consistency();

-- R-05: consecutive numbering with no gaps per series.
-- If number arrives NULL the next one is assigned; if it has a value, it must be the next one.
-- The advisory lock stops two simultaneous sales from getting the same number.
CREATE FUNCTION fn_invoice_numbering() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_next INTEGER;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('invoice_series_' || NEW.series));
    SELECT COALESCE(MAX(number), 0) + 1 INTO v_next FROM invoice WHERE series = NEW.series;
    IF NEW.number IS NULL THEN
        NEW.number := v_next;
    ELSIF NEW.number <> v_next THEN
        RAISE EXCEPTION 'R-05: series % must continue at number % (got %)', NEW.series, v_next, NEW.number;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER tg_invoice_numbering
BEFORE INSERT ON invoice
FOR EACH ROW EXECUTE FUNCTION fn_invoice_numbering();

-- R-06: each line sold deducts the dish's RECIPE ingredients from STOCK at the POS's
-- restaurant. If there is not enough stock, the CHECK (quantity >= 0) on STOCK rejects
-- the sale. Ingredients with no STOCK row at that restaurant are not deducted.
-- SECURITY DEFINER: the application role needs no direct UPDATE on STOCK.
CREATE FUNCTION fn_line_deducts_stock() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    UPDATE stock s
       SET quantity = s.quantity - r.quantity * NEW.quantity
      FROM recipe r, invoice i, device d
     WHERE r.dish_id = NEW.dish_id
       AND i.invoice_id = NEW.invoice_id
       AND d.device_id = i.device_id
       AND s.restaurant_id = d.restaurant_id
       AND s.ingredient_id = r.ingredient_id;
    RETURN NEW;
END $$;

CREATE TRIGGER tg_line_deducts_stock
AFTER INSERT ON invoice_line
FOR EACH ROW EXECUTE FUNCTION fn_line_deducts_stock();

-- R-07: price history. Creating a dish opens its first period; every change of price
-- or VAT rate closes the open period and opens a new one. Changing the name or the
-- description does not. clock_timestamp(): real time even with several changes in
-- the same transaction.
-- SECURITY DEFINER: the application can change a dish's price, but has no privilege
-- to write or fix the history by hand (03-roles.sql).
CREATE FUNCTION fn_dish_price_history() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_now TIMESTAMP := clock_timestamp();
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF NEW.price = OLD.price AND NEW.vat_rate = OLD.vat_rate THEN
            RETURN NEW;
        END IF;
        UPDATE dish_price_history
           SET valid_to = v_now
         WHERE dish_id = NEW.dish_id AND valid_to IS NULL;
    END IF;
    INSERT INTO dish_price_history (dish_id, valid_from, price, vat_rate)
    VALUES (NEW.dish_id, v_now, NEW.price, NEW.vat_rate);
    RETURN NEW;
END $$;

CREATE TRIGGER tg_dish_price_history
AFTER INSERT OR UPDATE OF price, vat_rate ON dish
FOR EACH ROW EXECUTE FUNCTION fn_dish_price_history();

COMMIT;

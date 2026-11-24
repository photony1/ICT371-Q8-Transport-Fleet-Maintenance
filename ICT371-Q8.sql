-- ICT371 Question 8: Transport Fleet Maintenance (PostgreSQL)
DROP VIEW IF EXISTS v_service_due;
DROP TABLE IF EXISTS service_alerts, trips, vehicles CASCADE;

-- (a) Tables and constraints
CREATE TABLE vehicles (
    vehicle_id            SERIAL PRIMARY KEY,
    registration          VARCHAR(20) NOT NULL UNIQUE,
    current_odometer      NUMERIC(10,1) NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer NUMERIC(10,1) NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT chk_service_odo CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id        SERIAL PRIMARY KEY,
    vehicle_id     INT NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on        DATE NOT NULL,
    start_odometer NUMERIC(10,1) NOT NULL CHECK (start_odometer >= 0),
    end_odometer   NUMERIC(10,1) NOT NULL CHECK (end_odometer > start_odometer)
);

CREATE TABLE service_alerts (
    vehicle_id       INT PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service NUMERIC(10,1) NOT NULL,
    flagged_on       DATE NOT NULL DEFAULT CURRENT_DATE
);

-- (b) Function: check 5,000 km service rule
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INT)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
DECLARE
    v_curr NUMERIC(10,1);
    v_last NUMERIC(10,1);
BEGIN
    SELECT current_odometer, last_service_odometer INTO v_curr, v_last
    FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle ID: %', p_vehicle_id;
    END IF;

    RETURN (v_curr - v_last) >= 5000;
END;
$$;

-- (c) Procedure: record trip (odometer updated by trigger)
CREATE OR REPLACE PROCEDURE pr_record_trip(p_vehicle_id INT, p_trip_on DATE, p_start NUMERIC, p_end NUMERIC)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
        RAISE EXCEPTION 'Unknown vehicle ID: %', p_vehicle_id;
    END IF;
    IF p_trip_on IS NULL THEN
        RAISE EXCEPTION 'Trip date cannot be NULL.';
    END IF;
    IF p_end IS NULL OR p_start IS NULL OR p_end <= p_start THEN
        RAISE EXCEPTION 'End odometer (%) must be greater than start odometer (%).', p_end, p_start;
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;

-- (d) Trigger: verify start odometer & update vehicle odometer once
CREATE OR REPLACE FUNCTION fn_trg_trip_odometer()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_curr NUMERIC(10,1);
BEGIN
    SELECT current_odometer INTO v_curr FROM vehicles WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle ID: %', NEW.vehicle_id;
    END IF;
    IF NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: end_odometer (%) <= start_odometer (%).', NEW.end_odometer, NEW.start_odometer;
    END IF;
    IF NEW.start_odometer <> v_curr THEN
        RAISE EXCEPTION 'Trip start odometer (%) must match vehicle current odometer (%).', NEW.start_odometer, v_curr;
    END IF;

    UPDATE vehicles SET current_odometer = NEW.end_odometer WHERE vehicle_id = NEW.vehicle_id;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_trips_before_insert
BEFORE INSERT ON trips
FOR EACH ROW EXECUTE FUNCTION fn_trg_trip_odometer();

-- (a) Seed data: 3 vehicles and 6 trips via procedure after trigger installation
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
('BBA 1024', 14200.0, 10000.0), -- 4,200 km since service (will cross 5,000 after trips)
('BCB 5589', 20500.0, 20000.0), -- 500 km since service (will stay below 5,000)
('CAA 8810', 34900.0, 30000.0); -- 4,900 km since service (will cross 5,000 after trips)

CALL pr_record_trip(1, CURRENT_DATE - 3, 14200.0, 14750.0);
CALL pr_record_trip(1, CURRENT_DATE - 1, 14750.0, 15200.0); -- 5,200 km since service (DUE)
CALL pr_record_trip(2, CURRENT_DATE - 2, 20500.0, 21100.0);
CALL pr_record_trip(2, CURRENT_DATE,     21100.0, 21800.0); -- 1,800 km since service (NOT DUE)
CALL pr_record_trip(3, CURRENT_DATE - 2, 34900.0, 35100.0); -- 5,100 km since service (DUE)
CALL pr_record_trip(3, CURRENT_DATE,     35100.0, 35450.0); -- 5,450 km since service (DUE)

-- (e) View: vehicles currently meeting service threshold
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration, (current_odometer - last_service_odometer) AS km_since_service
FROM vehicles
WHERE (current_odometer - last_service_odometer) >= 5000;

SELECT * FROM v_service_due;

-- (f) Index & EXPLAIN
-- Justification: Composite B-tree index on (vehicle_id, trip_on) supports equality lookup on
-- vehicle_id followed by an ordered range scan on trip_on.
CREATE INDEX idx_trips_vehicle_trip_on ON trips (vehicle_id, trip_on);

EXPLAIN ANALYZE
SELECT trip_id, trip_on, start_odometer, end_odometer
FROM trips
WHERE vehicle_id = 1 AND trip_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;

-- (g) Scheduled job: refresh service alerts every Monday at 06:00
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql AS $$
BEGIN
    DELETE FROM service_alerts sa
    WHERE NOT EXISTS (
        SELECT 1 FROM vehicles v
        WHERE v.vehicle_id = sa.vehicle_id
          AND (v.current_odometer - v.last_service_odometer) >= 5000
    );

    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id, (current_odometer - last_service_odometer), CURRENT_DATE
    FROM vehicles
    WHERE (current_odometer - last_service_odometer) >= 5000
    ON CONFLICT (vehicle_id) DO UPDATE
    SET km_since_service = EXCLUDED.km_since_service,
        flagged_on = EXCLUDED.flagged_on;
END;
$$;

CALL pr_refresh_service_alerts();

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh_fleet_service_alerts', '0 6 * * 1', $$CALL pr_refresh_service_alerts();$$);

-- ICT371 Advanced Database - Mulungushi University
-- Student: Augustine lukaki (202306775)
-- Question 8: Transport Fleet Maintenance
-- PostgreSQL / PL/pgSQL

-- A trip must begin at the vehicle's current odometer. The BEFORE INSERT trigger updates
-- the odometer once after validating the trip; the procedure itself does not update it.

-- ============================================================
-- 8(a) Tables and seed data
-- Create vehicles and trip tables first. Install the trigger and procedure before loading
-- the six trips.

CREATE TABLE vehicles (
 vehicle_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 registration VARCHAR(30) UNIQUE NOT NULL,
 current_odometer NUMERIC(12,2) NOT NULL CHECK(current_odometer>=0),
 last_service_odometer NUMERIC(12,2) NOT NULL CHECK(last_service_odometer>=0),
 CHECK(last_service_odometer<=current_odometer)
);
CREATE TABLE trips (
 trip_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 vehicle_id BIGINT NOT NULL REFERENCES vehicles(vehicle_id),
 trip_on DATE NOT NULL,start_odometer NUMERIC(12,2) NOT NULL,
 end_odometer NUMERIC(12,2) NOT NULL,
 CHECK(start_odometer>=0 AND end_odometer>start_odometer)
);
CREATE TABLE service_alerts (
 vehicle_id BIGINT PRIMARY KEY REFERENCES vehicles(vehicle_id),
 km_since_service NUMERIC(12,2) NOT NULL,flagged_on DATE NOT NULL
);
INSERT INTO vehicles(registration,current_odometer,last_service_odometer) VALUES
 ('ABC100',10000,6000),('DEF200',25000,21000),('GHI300',50000,44000);

-- ============================================================
-- 8(b) Service-due function
-- Returns TRUE at 5,000 km or more since the last service.

CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id BIGINT)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
DECLARE v_current NUMERIC(12,2);v_last NUMERIC(12,2);
BEGIN
 SELECT current_odometer,last_service_odometer INTO v_current,v_last
 FROM vehicles WHERE vehicle_id=p_vehicle_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown vehicle'; END IF;
 RETURN v_current-v_last>=5000;
END; $$;

-- ============================================================
-- 8(c) Trip procedure
-- The procedure validates inputs and inserts the trip. The trigger performs the odometer
-- update.

CREATE OR REPLACE PROCEDURE pr_record_trip(
 p_vehicle_id BIGINT,p_trip_on DATE,p_start NUMERIC(12,2),p_end NUMERIC(12,2)
) LANGUAGE plpgsql AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM vehicles WHERE vehicle_id=p_vehicle_id) THEN
  RAISE EXCEPTION 'Unknown vehicle';
 END IF;
 IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL OR p_end<=p_start THEN
  RAISE EXCEPTION 'Invalid trip date or mileage';
 END IF;
 INSERT INTO trips(vehicle_id,trip_on,start_odometer,end_odometer)
 VALUES(p_vehicle_id,p_trip_on,p_start,p_end);
END; $$;

-- ============================================================
-- 8(d) Odometer trigger
-- Locks the vehicle row, verifies the starting value, checks mileage and advances the
-- current odometer exactly once.

CREATE OR REPLACE FUNCTION fn_update_vehicle_odometer()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_current NUMERIC(12,2);
BEGIN
 SELECT current_odometer INTO v_current FROM vehicles
 WHERE vehicle_id=NEW.vehicle_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown vehicle'; END IF;
 IF NEW.start_odometer<>v_current THEN
  RAISE EXCEPTION 'Trip must start at current odometer (%)',v_current;
 END IF;
 IF NEW.end_odometer<=NEW.start_odometer THEN
  RAISE EXCEPTION 'End odometer must exceed start odometer';
 END IF;
 UPDATE vehicles SET current_odometer=NEW.end_odometer
 WHERE vehicle_id=NEW.vehicle_id;
 RETURN NEW;
END; $$;
CREATE TRIGGER trg_trip_odometer
BEFORE INSERT ON trips FOR EACH ROW
EXECUTE FUNCTION fn_update_vehicle_odometer();
-- Insert six consecutive trips; each start matches the preceding end/current value.
CALL pr_record_trip(1,CURRENT_DATE,10000,11000);
CALL pr_record_trip(1,CURRENT_DATE,11000,12000);
CALL pr_record_trip(2,CURRENT_DATE,25000,26000);
CALL pr_record_trip(2,CURRENT_DATE,26000,27000);
CALL pr_record_trip(3,CURRENT_DATE,50000,53000);
CALL pr_record_trip(3,CURRENT_DATE,53000,55000);

-- ============================================================
-- 8(e) Service-due view
-- Displays only vehicles at or above the service threshold.

CREATE OR REPLACE VIEW v_service_due AS
SELECT registration,current_odometer-last_service_odometer AS km_since_service
FROM vehicles WHERE current_odometer-last_service_odometer>=5000;

-- ============================================================
-- 8(f) Index
-- The composite index supports equality on vehicle_id and a range on trip_on.

CREATE INDEX idx_trips_vehicle_date ON trips(vehicle_id,trip_on);
EXPLAIN SELECT trip_id,start_odometer,end_odometer FROM trips
WHERE vehicle_id=1 AND trip_on>=CURRENT_DATE-30 AND trip_on<=CURRENT_DATE;

-- ============================================================
-- 8(g) Service alerts and schedule
-- Due vehicles are inserted/updated; alerts for vehicles no longer due are deleted.

CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql AS $$
BEGIN
 INSERT INTO service_alerts(vehicle_id,km_since_service,flagged_on)
 SELECT vehicle_id,current_odometer-last_service_odometer,CURRENT_DATE
 FROM vehicles WHERE current_odometer-last_service_odometer>=5000
 ON CONFLICT(vehicle_id) DO UPDATE SET
 km_since_service=EXCLUDED.km_since_service,flagged_on=EXCLUDED.flagged_on;
 DELETE FROM service_alerts a WHERE NOT EXISTS(
  SELECT 1 FROM vehicles v WHERE v.vehicle_id=a.vehicle_id
  AND v.current_odometer-v.last_service_odometer>=5000);
END; $$;
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('weekly-service-alerts','0 6 * * 1',
 $$CALL pr_refresh_service_alerts()$$);

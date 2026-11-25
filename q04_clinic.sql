-- Q4 Clinic Appointment Scheduling (PostgreSQL)

-- (a) Tables
CREATE TABLE patients (
    patient_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE doctors (
    doctor_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE appointments (
    appointment_id SERIAL PRIMARY KEY,
    patient_id INT NOT NULL REFERENCES patients(patient_id),
    doctor_id INT NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE NOT NULL,
    slot_time TIME NOT NULL CHECK (slot_time IN ('09:00', '10:00', '11:00', '12:00')),
    status VARCHAR(10) NOT NULL DEFAULT 'BOOKED' CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED'))
);

CREATE TABLE clinic_summary (
    summary_date DATE PRIMARY KEY,
    booked_count INT NOT NULL DEFAULT 0,
    attended_count INT NOT NULL DEFAULT 0,
    cancelled_count INT NOT NULL DEFAULT 0
);

INSERT INTO patients (full_name) VALUES ('Grace Mulenga'), ('Joseph Daka'), ('Ruth Simwanza');
INSERT INTO doctors (full_name) VALUES ('Dr. Banda'), ('Dr. Phiri'), ('Dr. Zimba');

-- (d) Trigger (installed first so the sample data is checked as well)
CREATE FUNCTION trg_check_clash() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status <> 'CANCELLED' AND EXISTS (
        SELECT 1 FROM appointments a
        WHERE a.doctor_id = NEW.doctor_id
          AND a.appointment_day = NEW.appointment_day
          AND a.slot_time = NEW.slot_time
          AND a.status <> 'CANCELLED'
          AND (TG_OP = 'INSERT' OR a.appointment_id <> NEW.appointment_id)
    ) THEN
        RAISE EXCEPTION 'Doctor % is already booked at % on %', NEW.doctor_id, NEW.slot_time, NEW.appointment_day;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_appointments_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION trg_check_clash();

INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
(1, 1, CURRENT_DATE - 2, '09:00', 'ATTENDED'),
(2, 1, CURRENT_DATE - 2, '10:00', 'CANCELLED'),
(3, 1, CURRENT_DATE - 2, '10:00', 'ATTENDED'),
(1, 2, CURRENT_DATE, '09:00', 'BOOKED'),
(2, 2, CURRENT_DATE, '11:00', 'BOOKED'),
(3, 3, CURRENT_DATE + 1, '12:00', 'BOOKED');

-- (b) Function
CREATE FUNCTION fn_daily_load(p_doctor_id INT, p_day DATE)
RETURNS INT AS $$
BEGIN
    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Doctor % does not exist', p_doctor_id;
    END IF;
    RETURN (SELECT COUNT(*) FROM appointments
            WHERE doctor_id = p_doctor_id AND appointment_day = p_day AND status <> 'CANCELLED');
END;
$$ LANGUAGE plpgsql;

SELECT fn_daily_load(1, CURRENT_DATE - 2);   -- 2
SELECT fn_daily_load(3, CURRENT_DATE);       -- 0

-- (c) Procedure
CREATE PROCEDURE pr_book_appointment(p_patient_id INT, p_doctor_id INT, p_day DATE, p_slot TIME)
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM patients WHERE patient_id = p_patient_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Patient % does not exist', p_patient_id;
    END IF;
    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Doctor % does not exist', p_doctor_id;
    END IF;
    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Date cannot be in the past';
    END IF;
    IF p_slot NOT IN ('09:00', '10:00', '11:00', '12:00') THEN
        RAISE EXCEPTION 'Slot % is not supported', p_slot;
    END IF;
    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;

CALL pr_book_appointment(1, 3, CURRENT_DATE + 2, '10:00');

-- these should fail
CALL pr_book_appointment(2, 3, CURRENT_DATE + 2, '10:00');   -- clash
CALL pr_book_appointment(1, 1, CURRENT_DATE - 1, '09:00');   -- past date
CALL pr_book_appointment(1, 1, CURRENT_DATE + 1, '13:00');   -- bad slot

-- (e) View
CREATE VIEW v_today_appointments AS
SELECT p.full_name AS patient_name, d.full_name AS doctor_name, a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors d ON d.doctor_id = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE AND a.status = 'BOOKED';

SELECT * FROM v_today_appointments;

-- (f) Index (not unique, many rows can share a day and doctor)
CREATE INDEX idx_appointments_day_doctor ON appointments (appointment_day, doctor_id);

EXPLAIN SELECT * FROM appointments WHERE appointment_day = CURRENT_DATE AND doctor_id = 2;

-- (g) Scheduled job
CREATE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    SELECT p_day,
           COUNT(*) FILTER (WHERE status = 'BOOKED'),
           COUNT(*) FILTER (WHERE status = 'ATTENDED'),
           COUNT(*) FILTER (WHERE status = 'CANCELLED')
    FROM appointments WHERE appointment_day = p_day
    ON CONFLICT (summary_date) DO UPDATE
    SET booked_count = EXCLUDED.booked_count,
        attended_count = EXCLUDED.attended_count,
        cancelled_count = EXCLUDED.cancelled_count;
END;
$$;

CALL pr_refresh_clinic_summary(CURRENT_DATE - 2);

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh_clinic_summary', '0 1 * * *', 'CALL pr_refresh_clinic_summary(CURRENT_DATE - 1)');

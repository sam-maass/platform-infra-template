-- hr_reporting: an existing database that apps can attach read-only.
-- Synthetic data only. Idempotent: bootstrap/ re-runs it when this file changes.

CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS reporting;

-- The raw table holds a column apps must not see (salary_band).
CREATE TABLE IF NOT EXISTS raw.employees (
  id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  department  text NOT NULL,
  location    text NOT NULL,
  start_date  date NOT NULL,
  salary_band text NOT NULL
);

-- Re-seeded on every run, so changing this file changes the data.
TRUNCATE raw.employees RESTART IDENTITY;

INSERT INTO raw.employees (department, location, start_date, salary_band)
SELECT CASE
         WHEN (n * 37) % 100 < 31 THEN 'Engineering'
         WHEN (n * 37) % 100 < 52 THEN 'Sales'
         WHEN (n * 37) % 100 < 67 THEN 'Customer Success'
         WHEN (n * 37) % 100 < 78 THEN 'Marketing'
         WHEN (n * 37) % 100 < 89 THEN 'People'
         ELSE 'Finance'
       END,
       CASE
         WHEN (n * 53 + 11) % 100 < 38 THEN 'Lisbon'
         WHEN (n * 53 + 11) % 100 < 62 THEN 'Paris'
         WHEN (n * 53 + 11) % 100 < 77 THEN 'Warsaw'
         WHEN (n * 53 + 11) % 100 < 90 THEN 'Stockholm'
         ELSE 'Vienna'
       END,
       DATE '2026-09-28' - (power(n, 1.25)::integer * 2),
       (ARRAY['B1', 'B2', 'B3', 'B4'])[1 + n % 4]
FROM generate_series(1, 240) AS n;

-- Curated views: the contract apps read. They hide salary_band.
CREATE OR REPLACE VIEW reporting.headcount_by_department AS
SELECT department, count(*) AS headcount
FROM raw.employees
GROUP BY department
ORDER BY headcount DESC, department;

CREATE OR REPLACE VIEW reporting.headcount_by_location AS
SELECT location, count(*) AS headcount
FROM raw.employees
GROUP BY location
ORDER BY headcount DESC, location;

CREATE OR REPLACE VIEW reporting.joiners_by_year AS
SELECT extract(year FROM start_date)::integer AS year, count(*) AS joiners
FROM raw.employees
GROUP BY 1
ORDER BY 1;

-- The access profile apps get: read the reporting views, nothing else.
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'hr_reporting_read') THEN
    CREATE ROLE hr_reporting_read NOLOGIN;
  END IF;
END
$$;

REVOKE ALL ON DATABASE hr_reporting FROM PUBLIC;
GRANT CONNECT ON DATABASE hr_reporting TO hr_reporting_read;
REVOKE ALL ON SCHEMA raw FROM PUBLIC;
GRANT USAGE ON SCHEMA reporting TO hr_reporting_read;
GRANT SELECT ON ALL TABLES IN SCHEMA reporting TO hr_reporting_read;

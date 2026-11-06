-- The lab's retail data: five TPC-DS tables copied from Trino's built-in
-- tpcds generator (scale factor 1) into Iceberg tables in iceberg.osi_demo.
-- Every statement is IF NOT EXISTS, so running the file again changes nothing.
--
-- Run it yourself to see what it does:
--   kubectl -n lakehouse exec deploy/trino -- trino -f /etc/lab/load-data.sql

CREATE SCHEMA IF NOT EXISTS iceberg.osi_demo;

-- Calendar, limited to the three years the sales cover. tpcds has the month
-- number (d_moy) but no month name, so derive one for nicer answers.
CREATE TABLE IF NOT EXISTS iceberg.osi_demo.date_dim AS
SELECT *, format_datetime(date_parse(cast(d_moy AS varchar), '%c'), 'MMMM') AS d_month_name
FROM tpcds.sf1.date_dim
WHERE d_year BETWEEN 2000 AND 2002;

CREATE TABLE IF NOT EXISTS iceberg.osi_demo.item AS SELECT * FROM tpcds.sf1.item;

CREATE TABLE IF NOT EXISTS iceberg.osi_demo.customer AS SELECT * FROM tpcds.sf1.customer;

-- The fact table: about 1.6 million sales line items, keeping only rows whose
-- keys resolve so every join in the model is clean.
CREATE TABLE IF NOT EXISTS iceberg.osi_demo.store_sales AS
SELECT ss.*
FROM tpcds.sf1.store_sales ss
WHERE ss.ss_store_sk IS NOT NULL
  AND ss.ss_item_sk IS NOT NULL
  AND ss.ss_customer_sk IS NOT NULL
  AND ss.ss_sold_date_sk IN (
    SELECT d_date_sk FROM tpcds.sf1.date_dim WHERE d_year BETWEEN 2000 AND 2002);

-- tpcds puts all 12 stores in Tennessee. Move every other store that has sales
-- to Texas, so a by-state answer has two rows and a Texas-only row filter has
-- something to filter.
CREATE TABLE IF NOT EXISTS iceberg.osi_demo.store AS
SELECT s.*
FROM tpcds.sf1.store s
WHERE false;

INSERT INTO iceberg.osi_demo.store
SELECT s_store_sk, s_store_id, s_rec_start_date, s_rec_end_date, s_closed_date_sk,
       s_store_name, s_number_employees, s_floor_space, s_hours, s_manager,
       s_market_id, s_geography_class, s_market_desc, s_market_manager,
       s_division_id, s_division_name, s_company_id, s_company_name,
       s_street_number, s_street_name, s_street_type, s_suite_number, s_city,
       s_county,
       CASE WHEN s_store_sk IN (
              SELECT sk FROM (
                SELECT sk, row_number() OVER (ORDER BY sk) AS rn
                FROM (SELECT DISTINCT ss_store_sk AS sk FROM iceberg.osi_demo.store_sales))
              WHERE rn % 2 = 0)
            THEN 'TX' ELSE 'TN' END AS s_state,
       s_zip, s_country, s_gmt_offset, s_tax_precentage
FROM tpcds.sf1.store
WHERE NOT EXISTS (SELECT 1 FROM iceberg.osi_demo.store LIMIT 1);

-- Check: row counts per table.
SELECT 'store_sales' AS table_name, count(*) AS row_count FROM iceberg.osi_demo.store_sales
UNION ALL SELECT 'date_dim', count(*) FROM iceberg.osi_demo.date_dim
UNION ALL SELECT 'customer', count(*) FROM iceberg.osi_demo.customer
UNION ALL SELECT 'item', count(*) FROM iceberg.osi_demo.item
UNION ALL SELECT 'store', count(*) FROM iceberg.osi_demo.store
ORDER BY 1;

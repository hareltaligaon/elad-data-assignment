-- One-time setup: ETL control schema and watermark table.
-- Run once on initial deployment. Safe to re-run (idempotent).
--
-- The watermark table tracks the highest UpdateDate processed per source table.
-- Each ETL run extracts only rows where UpdateDate > Last_UpdateDate,
-- minimising load on the production system.

CREATE SCHEMA IF NOT EXISTS etl;

CREATE TABLE IF NOT EXISTS etl.ETL_Watermark (
    Table_Name      VARCHAR(100) NOT NULL,
    Last_UpdateDate TIMESTAMP    NOT NULL DEFAULT '1900-01-01 00:00:00',
    Last_Run_TS     TIMESTAMP,
    CONSTRAINT pk_ETL_Watermark PRIMARY KEY (Table_Name)
);

INSERT INTO etl.ETL_Watermark (Table_Name, Last_UpdateDate)
SELECT 'Card_MoneyIn', '1900-01-01 00:00:00'
WHERE NOT EXISTS (SELECT 1 FROM etl.ETL_Watermark WHERE Table_Name = 'Card_MoneyIn');

INSERT INTO etl.ETL_Watermark (Table_Name, Last_UpdateDate)
SELECT 'Account_MoneyIn', '1900-01-01 00:00:00'
WHERE NOT EXISTS (SELECT 1 FROM etl.ETL_Watermark WHERE Table_Name = 'Account_MoneyIn');

INSERT INTO etl.ETL_Watermark (Table_Name, Last_UpdateDate)
SELECT 'MoneyIn_Extended_Details', '1900-01-01 00:00:00'
WHERE NOT EXISTS (SELECT 1 FROM etl.ETL_Watermark WHERE Table_Name = 'MoneyIn_Extended_Details');

-- Incremental ETL: populate gold.Fact_Money_In
--
-- Flow:
--   A. Snapshot watermarks
--   B. Extract changed rows from all three source tables
--   C. Deduplicate (keep latest UpdateDate per TransactionID)
--   D. Build complete picture: covers transactions where only Extended_Details changed
--   E. Transform + exchange rate lookup
--   F. MERGE into Fact_Money_In
--   G. Advance watermarks
--   H. Cleanup
--
-- Replace '<<BATCH_ID>>' with the orchestration run ID before executing.


-- A. Snapshot watermarks once to avoid repeated reads
CREATE TEMP TABLE wm_snapshot AS
SELECT Table_Name, Last_UpdateDate
FROM etl.ETL_Watermark
WHERE Table_Name IN ('Card_MoneyIn', 'Account_MoneyIn', 'MoneyIn_Extended_Details');


-- B. Extract rows changed since last run
CREATE TEMP TABLE stg_money_in_raw AS
    SELECT
        c.TransactionID,
        c.CustomerID,
        CAST(c.TransactionDate AS DATE) AS TransactionDate,
        c.Currency,
        c.Amount,
        c.CompanyID,
        c.CompanyCategory,
        c.UpdateDate,
        'CARD' AS Transaction_Source
    FROM prod.Card_MoneyIn c
    WHERE c.UpdateDate > (SELECT Last_UpdateDate FROM wm_snapshot WHERE Table_Name = 'Card_MoneyIn')

    UNION ALL

    SELECT
        a.TransactionID,
        a.CustomerID,
        CAST(a.TransactionDate AS DATE) AS TransactionDate,
        a.Currency,
        a.Amount,
        a.CompanyID,
        a.CompanyCategory,
        a.UpdateDate,
        'ACCOUNT' AS Transaction_Source
    FROM prod.Account_MoneyIn a
    WHERE a.UpdateDate > (SELECT Last_UpdateDate FROM wm_snapshot WHERE Table_Name = 'Account_MoneyIn');


CREATE TEMP TABLE stg_extended_raw AS
    SELECT
        e.TransactionID,
        e.TransactionMethod,
        e.In_fee,
        e.UpdateDate
    FROM prod.MoneyIn_Extended_Details e
    WHERE e.UpdateDate > (SELECT Last_UpdateDate FROM wm_snapshot WHERE Table_Name = 'MoneyIn_Extended_Details');


-- C. Deduplicate: keep only the latest version of each TransactionID
CREATE TEMP TABLE stg_money_in AS
SELECT * FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY TransactionID ORDER BY UpdateDate DESC) AS rn
    FROM stg_money_in_raw
) t WHERE rn = 1;

CREATE TEMP TABLE stg_extended AS
SELECT * FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY TransactionID ORDER BY UpdateDate DESC) AS rn
    FROM stg_extended_raw
) t WHERE rn = 1;


-- D. Collect all affected TransactionIDs (union of both staging sets)
--    This covers two cases:
--      (a) MoneyIn record changed
--      (b) Only Extended_Details changed — still need to re-merge the full transaction
CREATE TEMP TABLE stg_affected_ids AS
    SELECT TransactionID FROM stg_money_in
    UNION
    SELECT TransactionID FROM stg_extended;

-- For case (b): fetch the MoneyIn data from the existing fact row
CREATE TEMP TABLE stg_money_in_complete AS
SELECT
    COALESCE(s.TransactionID,      f.TransactionID)      AS TransactionID,
    COALESCE(s.CustomerID,         f.CustomerID)         AS CustomerID,
    COALESCE(s.TransactionDate,    DATEADD(day, 0, TO_DATE(CAST(f.TransactionDate_SK AS VARCHAR), 'YYYYMMDD'))) AS TransactionDate,
    COALESCE(s.Currency,           f.Currency)           AS Currency,
    COALESCE(s.Amount,             f.Amount)             AS Amount,
    COALESCE(s.CompanyID,          f.CompanyID)          AS CompanyID,
    COALESCE(s.CompanyCategory,    f.CompanyCategory)    AS CompanyCategory,
    COALESCE(s.UpdateDate,         f.UpdateDate)         AS UpdateDate,
    COALESCE(s.Transaction_Source, f.Transaction_Source) AS Transaction_Source
FROM stg_affected_ids a
LEFT JOIN stg_money_in s ON a.TransactionID = s.TransactionID
LEFT JOIN gold.Fact_Money_In f
    ON a.TransactionID = f.TransactionID
   AND s.TransactionID IS NULL;


-- E. Transform + exchange rate lookup
--
-- Exchange rate logic: for each non-USD transaction, find the most recent
-- Currencies row where rate_date <= TransactionDate (last-known-rate).
-- If no such rate exists, Amount_USD remains NULL.
CREATE TEMP TABLE stg_transformed AS
SELECT
    m.TransactionID,
    m.Transaction_Source,
    m.CustomerID,
    m.CompanyID,
    CAST(TO_CHAR(m.TransactionDate, 'YYYYMMDD') AS INTEGER) AS TransactionDate_SK,
    m.CompanyCategory,
    ex.TransactionMethod,
    m.Currency,
    m.Amount,
    ex.In_fee AS In_Fee,
    m.UpdateDate,
    CASE WHEN m.Currency = 'USD' THEN m.Amount        ELSE m.Amount * cr.Rate           END AS Amount_USD,
    CASE WHEN m.Currency = 'USD' THEN CAST(1.0 AS DECIMAL(18,6)) ELSE cr.Rate          END AS Exchange_Rate_Used,
    CASE WHEN m.Currency = 'USD' THEN m.TransactionDate ELSE cr.Rate_Date              END AS Exchange_Rate_Date
FROM stg_money_in_complete m
LEFT JOIN stg_extended ex ON m.TransactionID = ex.TransactionID
LEFT JOIN (
    SELECT CurrencyFrom, CurrencyTo, Rate, CAST(Date AS DATE) AS Rate_Date
    FROM prod.Currencies
    WHERE CurrencyTo = 'USD'
) cr
    ON  cr.CurrencyFrom = m.Currency
    AND cr.CurrencyTo   = 'USD'
    AND cr.Rate_Date = (
        SELECT MAX(CAST(c2.Date AS DATE))
        FROM prod.Currencies c2
        WHERE c2.CurrencyFrom = m.Currency
          AND c2.CurrencyTo   = 'USD'
          AND CAST(c2.Date AS DATE) <= m.TransactionDate
    );


-- F. Upsert into Fact_Money_In
--    MERGE is atomic — no explicit transaction needed.
MERGE INTO gold.Fact_Money_In AS target
USING stg_transformed AS source
ON target.TransactionID = source.TransactionID

WHEN MATCHED THEN
    UPDATE SET
        Transaction_Source = source.Transaction_Source,
        CustomerID         = source.CustomerID,
        CompanyID          = source.CompanyID,
        TransactionDate_SK = source.TransactionDate_SK,
        CompanyCategory    = source.CompanyCategory,
        TransactionMethod  = source.TransactionMethod,
        Currency           = source.Currency,
        Amount             = source.Amount,
        In_Fee             = source.In_Fee,
        Amount_USD         = source.Amount_USD,
        Exchange_Rate_Used = source.Exchange_Rate_Used,
        Exchange_Rate_Date = source.Exchange_Rate_Date,
        UpdateDate         = source.UpdateDate,
        ETL_Load_Timestamp = GETDATE(),
        ETL_Batch_ID       = '<<BATCH_ID>>'

WHEN NOT MATCHED THEN
    INSERT (
        TransactionID, Transaction_Source, CustomerID, CompanyID,
        TransactionDate_SK, CompanyCategory, TransactionMethod,
        Currency, Amount, In_Fee, Amount_USD,
        Exchange_Rate_Used, Exchange_Rate_Date,
        UpdateDate, ETL_Load_Timestamp, ETL_Batch_ID
    )
    VALUES (
        source.TransactionID, source.Transaction_Source, source.CustomerID, source.CompanyID,
        source.TransactionDate_SK, source.CompanyCategory, source.TransactionMethod,
        source.Currency, source.Amount, source.In_Fee, source.Amount_USD,
        source.Exchange_Rate_Used, source.Exchange_Rate_Date,
        source.UpdateDate, GETDATE(), '<<BATCH_ID>>'
    );


-- G. Advance watermarks
UPDATE etl.ETL_Watermark
SET Last_UpdateDate = (SELECT COALESCE(MAX(UpdateDate), Last_UpdateDate) FROM stg_money_in_raw WHERE Transaction_Source = 'CARD'),
    Last_Run_TS = GETDATE()
WHERE Table_Name = 'Card_MoneyIn';

UPDATE etl.ETL_Watermark
SET Last_UpdateDate = (SELECT COALESCE(MAX(UpdateDate), Last_UpdateDate) FROM stg_money_in_raw WHERE Transaction_Source = 'ACCOUNT'),
    Last_Run_TS = GETDATE()
WHERE Table_Name = 'Account_MoneyIn';

UPDATE etl.ETL_Watermark
SET Last_UpdateDate = (SELECT COALESCE(MAX(UpdateDate), Last_UpdateDate) FROM stg_extended_raw),
    Last_Run_TS = GETDATE()
WHERE Table_Name = 'MoneyIn_Extended_Details';


-- H. Cleanup staging tables
DROP TABLE IF EXISTS wm_snapshot;
DROP TABLE IF EXISTS stg_money_in_raw;
DROP TABLE IF EXISTS stg_extended_raw;
DROP TABLE IF EXISTS stg_money_in;
DROP TABLE IF EXISTS stg_extended;
DROP TABLE IF EXISTS stg_affected_ids;
DROP TABLE IF EXISTS stg_money_in_complete;
DROP TABLE IF EXISTS stg_transformed;

-- DDL: Fact_Money_In
-- Target: Amazon Redshift Serverless
-- Schemas: gold (serving layer), etl (control tables)

-- Calendar dimension — DISTSTYLE ALL replicates it to all nodes (small table, avoids broadcast joins)
CREATE TABLE IF NOT EXISTS gold.Dim_Date (
    Date_SK      INTEGER     NOT NULL,  -- YYYYMMDD
    Full_Date    DATE        NOT NULL,
    Year         SMALLINT    NOT NULL,
    Quarter      SMALLINT    NOT NULL,
    Month        SMALLINT    NOT NULL,
    Month_Name   VARCHAR(10) NOT NULL,
    Week_Of_Year SMALLINT    NOT NULL,
    Day_Of_Month SMALLINT    NOT NULL,
    Day_Of_Week  SMALLINT    NOT NULL,
    Day_Name     VARCHAR(10) NOT NULL,
    Is_Weekend   BOOLEAN     NOT NULL,
    Is_Holiday   BOOLEAN     NOT NULL DEFAULT FALSE,
    CONSTRAINT pk_Dim_Date PRIMARY KEY (Date_SK)
)
DISTSTYLE ALL
SORTKEY (Date_SK);


-- Fact table — grain: one row per MoneyIn transaction (Card or Account)
--
-- Design notes:
--   Transaction_Source ('CARD' / 'ACCOUNT') distinguishes the two source tables.
--   TransactionMethod and In_Fee come from MoneyIn_Extended_Details (NULL when no record exists).
--   Amount_USD uses the last available exchange rate where rate_date <= TransactionDate.
--   Amount_USD is NULL when no preceding rate exists or when Currency = 'USD'.
--   Exchange_Rate_Used / Exchange_Rate_Date are kept for auditability.
CREATE TABLE IF NOT EXISTS gold.Fact_Money_In (
    Fact_MoneyIn_SK    BIGINT        IDENTITY(1,1) NOT NULL,
    TransactionID      VARCHAR(50)   NOT NULL,
    Transaction_Source VARCHAR(10)   NOT NULL,  -- 'CARD' or 'ACCOUNT'
    TransactionDate_SK INTEGER       NOT NULL,  -- FK to Dim_Date (YYYYMMDD)
    CustomerID         VARCHAR(50)   NOT NULL,
    CompanyID          VARCHAR(50)   NOT NULL,
    CompanyCategory    VARCHAR(100),
    TransactionMethod  VARCHAR(50),
    Currency           CHAR(3)       NOT NULL,
    Amount             DECIMAL(18,4) NOT NULL,
    In_Fee             DECIMAL(18,4),
    Amount_USD         DECIMAL(18,4),
    Exchange_Rate_Used DECIMAL(18,6),
    Exchange_Rate_Date DATE,
    UpdateDate         TIMESTAMP     NOT NULL,
    ETL_Load_Timestamp TIMESTAMP     NOT NULL DEFAULT GETDATE(),
    ETL_Batch_ID       VARCHAR(100),
    CONSTRAINT pk_Fact_MoneyIn       PRIMARY KEY (Fact_MoneyIn_SK),
    CONSTRAINT uq_Fact_MoneyIn_TxnID UNIQUE (TransactionID)
)
DISTSTYLE KEY
DISTKEY (CustomerID)
COMPOUND SORTKEY (TransactionDate_SK, Transaction_Source);

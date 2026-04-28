# Data Platform Architecture — AWS Design Document

## Overview

This document describes the data platform architecture for a company that collects and processes data from multiple external sources to support AI and BI products.

The platform is built on AWS managed services, uses the **Medallion (Bronze / Silver / Gold) layering pattern**, and handles two ingestion paths:

- **Batch ingestion** — JSON and CSV files uploaded daily to Amazon S3
- **Streaming ingestion** — Real-time application events streamed in JSON format

The design targets multi-TB daily throughput with minimal operational overhead, and is built to accommodate new data sources and customer requirements without major rework.

---

## 1. Architecture

See `architecture_diagram.drawio` for the visual representation.

### Ingestion paths

**Batch path**

```
S3 (raw landing)
  → EventBridge Scheduler (daily trigger)
  → Step Functions (orchestration)
  → Glue Job: Bronze (raw → Parquet)
  → Glue Job: Silver (clean + validate)
  → Glue Job: Gold (dimensional model)
  → Redshift Serverless (data warehouse)
```

**Streaming path**

```
Application events
  → Kinesis Data Streams
  → Lambda (transform + validate)
  → Kinesis Data Firehose
  → S3 Bronze Streaming
  → Glue Job: Silver (hourly merge)
  → S3 Silver (unified with batch)
```

**Serving layer**

```
Redshift Serverless  →  Amazon QuickSight (BI dashboards)
S3 Gold (Parquet)    →  Amazon Athena (ad-hoc SQL)
```

---

## 2. AWS Services Selection and Justification

### Storage

| Service | Stage | Justification |
|---------|-------|---------------|
| **Amazon S3** | All layers (Bronze, Silver, Gold) | Practically unlimited scale, 11-nines durability, and native integration with every AWS analytics service. S3 Intelligent-Tiering moves data to cheaper storage classes automatically as access drops — no manual lifecycle rules needed. Versioning keeps the full history of each file, useful for reprocessing after a pipeline bug. |
| **Amazon Redshift Serverless** | Data warehouse (Gold) | Columnar storage, auto-scales from 8 to 512 RPUs based on actual query load — no cluster sizing or reservation needed. Redshift Spectrum lets us query S3 Gold Parquet directly without loading everything into the warehouse, which is useful for cold historical data. AQUA accelerates repeated analytical queries at no extra cost. |

### Ingestion

| Service | Stage | Justification |
|---------|-------|---------------|
| **Amazon Kinesis Data Streams** | Streaming ingestion | Fully managed, millisecond latency, ordered within a shard, 7-day replay retention. Scales by adding shards (1 MB/s write, 2 MB/s read per shard) without application changes. Native Lambda trigger for serverless consumers. |
| **Amazon Kinesis Data Firehose** | Streaming delivery to S3 | Buffers Kinesis records and writes micro-batches (configurable: up to 128 MB or 300 seconds) directly to S3 in JSON, without custom delivery code. No infrastructure to manage. |
| **AWS Lambda** | Streaming transformation | Stateless, event-driven compute for per-record validation and lightweight enrichment before Firehose delivery. Dead-letter queue on SQS handles records that fail repeatedly without blocking the stream. |

### Processing (ETL)

| Service | Stage | Justification |
|---------|-------|---------------|
| **AWS Glue (PySpark)** | Bronze → Silver → Gold transformations | Serverless Spark with automatic DPU scaling. G.2X workers (8 vCPU, 32 GB RAM) handle multi-TB daily volumes. Glue Job Bookmarks track processed S3 partitions, preventing reprocessing. Native Glue Data Catalog integration means schema changes are picked up without code changes. Chosen over EMR because there is no need to manage cluster lifecycle for batch workloads. |
| **AWS Glue Data Quality (DQDL)** | Silver layer validation | Declarative rule engine for null checks, range checks, referential integrity, and custom SQL rules. Results are published to CloudWatch as custom metrics, enabling alarms on quality degradation. |
| **AWS Glue Crawlers** | Schema discovery | Automatically infer and register schemas from new S3 files into the Glue Data Catalog. Triggered at the start of each Step Functions run. |

### Orchestration

| Service | Stage | Justification |
|---------|-------|---------------|
| **AWS Step Functions (Standard Workflows)** | Pipeline orchestration | Visual state machine with per-step retry policies (exponential backoff), error-catch branches, and execution history for audit. Each Glue job is a Task state; failures route to an SNS notification state rather than silently stopping. Execution ARN is injected into each ETL run as the batch lineage identifier. |
| **Amazon EventBridge Scheduler** | Cron triggering | Serverless cron scheduler that invokes Step Functions at a fixed daily time (e.g., 02:00 UTC). No EC2 or server required. Timezone-aware schedules avoid DST edge cases. |

### Cataloguing and Metadata

| Service | Justification |
|---------|---------------|
| **AWS Glue Data Catalog** | Single source of truth for all table schemas across S3, Redshift, and Athena. Changes made in one service are reflected across all consumers without manual coordination. |

### Querying and Analytics

| Service | Justification |
|---------|---------------|
| **Amazon Athena** | Serverless SQL on S3 Parquet. Pay per query (per TB scanned). Used by data analysts for exploratory queries on Silver and Gold layers without touching Redshift. |
| **Amazon QuickSight** | Native Redshift connector with SPICE in-memory acceleration for fast dashboards. Enterprise-grade row-level security and integration with Lake Formation for per-user data access control. |

### Access Control and Security

| Service | Justification |
|---------|---------------|
| **AWS Lake Formation** | Provides column-level and row-level access control on top of the Glue Data Catalog. Enables per-team and per-customer data isolation in a multi-tenant setup without duplicating data. Tag-based access control (LF-Tags) makes policy management scalable as the number of tables grows. |
| **AWS IAM** | Service-level identity and permissions. Each component (Glue, Lambda, Step Functions, Redshift) runs under its own role with the minimum permissions required. No shared roles between services. |
| **AWS KMS** | Customer-managed keys (CMK) for encryption at rest on S3, Redshift, Kinesis, and Lambda environment variables. Separate CMK per environment (dev / staging / prod) limits blast radius of a key compromise. Automatic annual key rotation. |
| **AWS Secrets Manager** | Stores all credentials (Redshift passwords, API keys, JDBC connection strings). Automatic rotation every 30 days. Application code references secret ARNs — no hard-coded credentials anywhere in the pipeline. |

### Monitoring and Alerting

| Service | Justification |
|---------|---------------|
| **Amazon CloudWatch** | Unified metrics and logs for all pipeline components. Custom metrics from Glue Data Quality results. Composite alarms correlate multiple signals (e.g., job failure + data quality degradation) before paging on-call. |
| **Amazon SNS** | Fan-out notification delivery (email, PagerDuty, Slack webhook) on Step Functions failure events or CloudWatch alarm state changes. |
| **AWS CloudTrail** | API-level audit trail for all actions in the account. Stored in S3 with a 90-day hot tier and 7-year Glacier archive for compliance. |

### Infrastructure and Deployment

| Service | Justification |
|---------|---------------|
| **AWS CDK (Python)** | Infrastructure-as-code for all resources. Version-controlled alongside pipeline code in the same repository. Enables reproducible environment promotion (dev → staging → prod). |
| **AWS CodePipeline + CodeBuild** | CI/CD for Glue scripts, Lambda code, Step Functions definitions, and CDK stacks. Runs unit tests and CDK diff on every pull request. |

---

## 3. File Formats by Processing Stage

| Layer | S3 Prefix | Format | Compression | Partitioning | Rationale |
|-------|-----------|--------|-------------|--------------|-----------|
| Bronze Raw | `s3://bucket/bronze/raw/` | JSON / CSV (as-is) | None | `source=X/year=YYYY/month=MM/day=DD` | Preserves exact source fidelity. Enables full reprocessing from the original file if a downstream bug is found. |
| Bronze Processed | `s3://bucket/bronze/processed/` | Parquet | Snappy | `year=YYYY/month=MM/day=DD` | Converts row-oriented source files to columnar format. Snappy offers fast decompression with moderate compression ratio — good for frequently read bronze data. Schema is enforced at this stage. |
| Silver | `s3://bucket/silver/` | Parquet | ZSTD | `year=YYYY/month=MM/day=DD` | ZSTD achieves 2–3× better compression than Snappy with acceptable decompression speed. Silver data is read less frequently than Gold and benefits more from storage savings. |
| Gold (S3) | `s3://bucket/gold/` | Parquet | ZSTD | `year=YYYY/month=MM/day=DD` | Queried by Athena and Redshift Spectrum. Parquet column pruning and predicate pushdown reduce scanned bytes and cost. |
| Gold (Redshift) | Redshift internal | Redshift columnar (AZ64 / LZO) | Automatic | DISTKEY / SORTKEY | Loaded from S3 Gold via COPY command for low-latency BI queries. Redshift manages its own storage format. |
| Streaming Bronze | `s3://bucket/bronze/streaming/` | JSON (Firehose micro-batch) | GZIP | `year=YYYY/month=MM/day=DD/hour=HH` | Kinesis Firehose writes JSON natively. Hour-level partitioning enables efficient hourly Glue merge jobs. Merged into Silver as Parquet on each hourly run. |

**Why Parquet:**
Parquet is the standard for analytical workloads. Columnar layout means a query that reads 3 columns out of 30 only touches those 3 on disk. Row-group statistics let engines skip entire blocks that can't match a WHERE filter. Athena and Redshift Spectrum are both optimized for it out of the box.

**Why not Delta Lake or Apache Iceberg:**
Both are good options and worth considering as a future step — they add ACID transactions, schema evolution, and time-travel on S3. For now, the workload is mostly append-heavy with occasional partition overwrites, so standard Parquet with Hive partitioning is simpler and has fewer moving parts. The migration path is documented in Section 7.

---

## 4. Data Modeling Approach

### Medallion Architecture

The platform uses three logical data layers, each with a distinct quality contract.

**Bronze — Raw / Landed**

Bronze is essentially the source data as-is, converted to Parquet to save storage but otherwise untouched. The idea is that if something goes wrong downstream, we can always reprocess from scratch.

- Source files converted to Parquet; all original fields preserved
- Metadata added: `ingestion_timestamp`, `source_file_name`, `source_system`
- No type casting, no deduplication, no business logic
- Retained indefinitely (S3 Intelligent-Tiering manages the cost automatically)

**Silver — Cleaned / Validated / Conformed**

Silver is where data gets shaped into something reliable enough to build on. Types are enforced, duplicates are removed, and quality rules run on every batch.

- Type casting (string dates → DATE, string amounts → DECIMAL)
- Deduplication on business key + UpdateDate (keep latest version per record)
- Null handling and default value assignment
- PII masking or tokenization for sensitive fields
- Glue DQDL quality rules run here; records that fail go to a quarantine prefix, not silently dropped
- Key tables: `silver.card_money_in`, `silver.account_money_in`, `silver.money_in_extended_details`

**Gold — Dimensional Model / Analytics-Ready**

The Gold layer applies dimensional modelling (star schema) for optimal BI query performance. Data is loaded into Redshift Serverless and also written to S3 for Athena access.

Core tables for the pay-pay domain:

| Table | Type | Description |
|-------|------|-------------|
| `Fact_Money_In` | Fact | One row per transaction; unified Card + Account; Amount_USD derived |
| `Dim_Customer` | Dimension | Customer attributes and segments |
| `Dim_Company` | Dimension | Company metadata and category hierarchy |
| `Dim_Date` | Dimension | Full calendar including week, quarter, holiday flags |
| `Dim_Currency` | Dimension | Currency codes, names, and geographic region |

Redshift physical design:
- `DISTKEY (CustomerID)` on fact and large dimension tables — co-locates rows for joins
- `COMPOUND SORTKEY (TransactionDate_SK, Transaction_Source)` — accelerates the most common filter patterns (date range + source type)
- `DISTSTYLE ALL` on small dimensions (Dim_Date, Dim_Currency) — replicates to every node, eliminating broadcast joins

---

## 5. Automation and Monitoring

### Batch Pipeline Orchestration

The daily batch pipeline is triggered by an EventBridge Scheduler rule at 02:00 UTC and executed by a Step Functions Standard Workflow.

```
EventBridge Scheduler (02:00 UTC)
  └─ Step Functions Execution
       ├─ Task: Glue Crawler (Bronze Raw prefix → update Glue Catalog)
       ├─ Task: Glue Job — Bronze (convert to Parquet, enforce schema)
       ├─ Task: Glue Job — Silver (clean, validate, DQDL quality check)
       ├─ Task: Glue Job — Gold (dimensional model population)
       ├─ Task: Redshift COPY (load Gold Parquet → Redshift tables)
       └─ Task: SNS Notification (success or failure summary)
```

Every Task state is configured with:
- **Retry**: 3 attempts, 30-second initial interval, 2× exponential backoff
- **Catch**: routes to a dedicated failure state that publishes to an SNS topic

### Streaming Pipeline Orchestration

The streaming path is continuous and self-managed:

- Kinesis Data Streams receives events from the application
- Lambda consumes the stream, validates each record, and forwards valid records to Kinesis Firehose
- Lambda DLQ (SQS) holds records that fail repeated processing without blocking the stream
- Firehose buffers and writes to S3 Bronze Streaming every 60 seconds or 128 MB
- An hourly EventBridge rule triggers a Step Functions execution that runs the Silver Glue job to merge streaming bronze into the Silver layer

### Monitoring

| Signal | Mechanism | Alert |
|--------|-----------|-------|
| Glue job failure | CloudWatch alarm on Glue job `failed` metric | SNS → PagerDuty + email |
| Data quality degradation | Glue DQDL results published as custom CloudWatch metrics | SNS when quality score drops below threshold |
| Streaming lag | CloudWatch alarm on Kinesis `GetRecords.IteratorAgeMilliseconds` | SNS if iterator age > 5 minutes |
| S3 PUT anomaly | CloudWatch metric math on S3 `PutRequests` | SNS if daily file count deviates >50% from 7-day average |
| Redshift query performance | Redshift system views + CloudWatch | SNS if p95 query duration exceeds SLA |

A CloudWatch Dashboard consolidates all pipeline health metrics into a single operational view for on-call engineers.

### Failure Recovery

- Glue Job Bookmarks prevent reprocessing already-processed S3 partitions after a retry
- Watermark table (see `etl_watermark_setup.sql`) ensures the ETL never misses an update window even after a failed run
- Bad records from quality checks are written to `s3://bucket/quarantine/` with the original record and the failing rule for manual review
- All Step Functions execution history is retained for 90 days for post-incident investigation

---

## 6. Security and Access Management

### IAM Roles (Least Privilege)

Each service runs under its own IAM role with only the permissions it actually needs — no shared roles between components.

| Role | Permissions |
|------|-------------|
| `GlueExecutionRole` | Read/write specific S3 prefixes, read Secrets Manager for DB credentials, read/write Glue Catalog, publish CloudWatch metrics |
| `LambdaExecutionRole` | Read Kinesis stream, write to Firehose, write to SQS DLQ, publish CloudWatch logs |
| `StepFunctionsRole` | Start Glue jobs, invoke Lambda, publish to SNS, read/write Step Functions state |
| `RedshiftServiceRole` | Read S3 Gold prefix for COPY commands |

No wildcards on resource ARNs — every permission is scoped to specific resource ARNs.

### Encryption at Rest

All data stores use server-side encryption with AWS KMS customer-managed keys (CMK):

- S3 buckets: SSE-KMS, one CMK per environment
- Redshift cluster: KMS encryption enabled at cluster creation
- Kinesis Data Streams: SSE with KMS CMK
- Lambda environment variables: encrypted with KMS

### Encryption in Transit

- All API calls use HTTPS/TLS 1.2+
- Redshift SSL enforcement: `require_ssl = true` in parameter group
- No data crosses the public internet — all traffic stays within the VPC via gateway and interface endpoints

### Network Security

- Glue jobs run in a customer-managed VPC, private subnets, no public IP
- S3 accessed via VPC Gateway Endpoints (traffic stays on AWS backbone)
- Redshift in private VPC subnet; BI tools connect via AWS PrivateLink or VPN
- VPC Flow Logs enabled on all subnets and stored in S3 for security analysis

### Fine-Grained Access Control (Lake Formation)

Lake Formation is the authorization layer for all data in the Glue Data Catalog:

| Persona | Access |
|---------|--------|
| Data Platform Team | Full admin on all layers |
| Data Analysts | SELECT on Silver and Gold; PII columns masked |
| Data Scientists | SELECT on Silver with PII tokenised; no access to Bronze |
| BI / QuickSight | SELECT on Gold only, via QuickSight role |

Row-level security on `Fact_Money_In` can be applied per company or region for multi-tenant deployments where different customers should only see their own transactions.

### Audit and Compliance

- **CloudTrail**: all AWS API calls logged to S3 with 90-day hot retention and 7-year Glacier archive
- **S3 Access Logs**: per-object access recorded for the Bronze bucket
- **Redshift Audit Logging**: user activity and connection logs enabled
- **Secrets Manager**: every secret access is logged in CloudTrail

---

## 7. Scalability Considerations

### Current Scale: Multi-TB Daily

The architecture is sized for multi-TB daily ingestion without any manual intervention:

- **S3**: no capacity limit; throughput scales linearly
- **Glue**: G.2X workers with `--enable-auto-scaling` dynamically add DPUs during peak loads and release them when idle, keeping cost proportional to work
- **Kinesis**: shards can be split via API or with the Kinesis Scaling Utility when throughput grows; Enhanced Fan-Out allows multiple consumers at 2 MB/s each without contention
- **Redshift Serverless**: RPUs scale automatically within the configured max; Concurrency Scaling handles burst query workloads by routing overflow to transient clusters

### Future Optimisations for Larger Scale

**Partition pruning and file sizing**

Maintain target Parquet file sizes of 128–512 MB. Files smaller than 64 MB cause excessive S3 LIST calls and slow Glue job startup. Implement a periodic compaction job (Glue or Spark) to merge small files created by streaming writes.

**Data format upgrade to Apache Iceberg**

Iceberg provides ACID transactions, partition evolution, and time-travel on S3. When in-place row-level updates become frequent (e.g., late-arriving corrections to MoneyIn records), Iceberg eliminates the need for the DELETE + INSERT upsert pattern in the ETL and reduces the amount of data rewritten per run.

**Query optimisation on Redshift**

- Automatic Table Optimisation (ATO): Redshift analyses query patterns and adjusts DISTKEY / SORTKEY automatically
- Materialised Views: pre-aggregate common BI query patterns (e.g., daily revenue by company category) and refresh them automatically after each ETL run
- Redshift ML: build and run in-database anomaly detection on transaction data without moving data to SageMaker

**Multi-region active-active**

- S3 Cross-Region Replication for disaster recovery (RPO ~15 minutes)
- Redshift automated snapshots copied to a secondary region
- Route 53 health checks route BI traffic to the secondary region during a primary region outage

**Customer adaptability**

- Parameterised Glue jobs and Step Functions allow per-customer configuration (different S3 buckets, schemas, processing schedules) without code changes
- Lake Formation tag-based access control enables per-customer data isolation in a shared infrastructure model
- New data sources can be added by deploying a new Glue Crawler and registering a new Step Functions branch — no changes to existing pipeline stages

---

## Architecture Decision Records

### ADR-001: Glue over EMR

**Decision**: Use AWS Glue for all batch ETL jobs.
**Reason**: No cluster to manage. Glue G.2X workers auto-scale to match the daily batch load and shut down when done, so we pay only for what we use. EMR would make sense if we needed persistent clusters for stateful Spark Structured Streaming or complex ML pipelines, but for scheduled batch jobs Glue is simpler and cheaper.

### ADR-002: Redshift Serverless over Snowflake or Databricks

**Decision**: Use Amazon Redshift Serverless as the central data warehouse.
**Reason**: The stack is fully on AWS. Redshift Serverless removes cluster management entirely, integrates natively with S3 via Spectrum, and fits naturally alongside Glue and Lake Formation. Snowflake or Databricks would introduce cross-cloud egress costs and additional IAM federation work without a clear benefit in this context.

### ADR-003: Standard Parquet over Delta Lake / Iceberg (current phase)

**Decision**: Use Hive-style partitioned Parquet for all S3 layers.
**Reason**: The current workload is append-heavy (new daily files) with occasional full-partition overwrites. Delta Lake and Iceberg add value primarily for row-level updates and time-travel, which are not required in the current phase. Migrating to Iceberg is explicitly documented as a future optimisation (see Section 7).

### ADR-004: Step Functions over Apache Airflow (MWAA)

**Decision**: Use AWS Step Functions for pipeline orchestration.
**Reason**: No servers, no scheduler to maintain, and per-execution pricing. The retry/catch semantics are built in — each job step has its own retry policy and a failure branch that fires an SNS alert. MWAA (managed Airflow) would be the better choice if the team already runs Airflow or needs complex dynamic DAGs, but for a linear Glue job pipeline Step Functions is the lighter option.

### ADR-005: Kinesis over Apache Kafka (Amazon MSK)

**Decision**: Use Amazon Kinesis Data Streams for real-time ingestion.
**Reason**: Kinesis is fully managed with zero broker configuration. For this use case — ingesting application events into S3 — it provides sufficient throughput with minimal operational overhead.

**When Kafka (Amazon MSK) would be preferred:**

| Criteria | Kinesis | Kafka (MSK) |
|----------|---------|-------------|
| Message retention | Up to 7 days | Unlimited (disk-bound) |
| Throughput ceiling | Shard-based (1 MB/s per shard) | Very high (topic partitions scale further) |
| Consumer groups | Limited fan-out | Unlimited independent consumer groups |
| Ecosystem | AWS-only | Open-source: Kafka Connect, Kafka Streams, Flink, Spark |
| Operational overhead | Zero | Medium (broker sizing, replication factor) |
| Re-replay flexibility | Limited | Full — consumers track their own offsets |

**Kafka would be chosen if:**
- Multiple independent downstream systems (BI, ML, fraud detection) need to consume the same stream independently at different speeds
- Event retention beyond 7 days is required (e.g., full replay for a new ML model)
- The organisation already operates Kafka and wants a unified streaming platform across cloud and on-premise

Amazon MSK (Managed Streaming for Apache Kafka) removes the need to run Kafka on EC2 and provides the open-source flexibility with AWS-managed brokers, automatic patching, and CloudWatch integration.


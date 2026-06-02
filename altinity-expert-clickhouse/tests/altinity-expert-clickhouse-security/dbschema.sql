-- Base schema for altinity-expert-clickhouse-security skill test
-- The runner creates the database and runs this with --database set, so names are unqualified.
-- Must be idempotent (safe to run multiple times).

-- Clean up objects from previous runs (global objects are dropped in post.sql).
DROP VIEW IF EXISTS v_sensitive;
DROP TABLE IF EXISTS sensitive_events;
DROP TABLE IF EXISTS ext_feed;
DROP TABLE IF EXISTS ext_s3;

-- Table holding sensitive columns; used for row-policy bypass and definer-view scenarios.
CREATE TABLE sensitive_events
(
    tenant      String,
    user_id     UInt64,
    email       String,
    ssn         String,
    amount      Float64,
    event_time  DateTime
)
ENGINE = MergeTree()
ORDER BY (tenant, user_id);

INSERT INTO sensitive_events
SELECT
    if(rand() % 2 = 0, 'tenant_a', 'tenant_b') AS tenant,
    number AS user_id,
    concat('user', toString(number), '@example.com') AS email,
    concat('000-00-', leftPad(toString(number % 10000), 4, '0')) AS ssn,
    round(randCanonical() * 1000, 2) AS amount,
    now() - toIntervalMinute(number) AS event_time
FROM numbers(1000);

-- IGNORE_ERRORS
-- Scenario 4: additional signals that may depend on version/engine availability.
-- Marked IGNORE_ERRORS so an unsupported statement does not fail the whole test;
-- these are "should detect", not "must detect".

DROP USER IF EXISTS sec_multi_auth;
DROP TABLE IF EXISTS ext_feed;
DROP TABLE IF EXISTS ext_s3;

-- Multiple auth methods: a strong primary undermined by a plaintext fallback.
-- (Multiple authentication methods require a recent ClickHouse version.)
CREATE USER sec_multi_auth
    IDENTIFIED WITH bcrypt_password BY 'Primary-Strong-Passphrase-5', plaintext_password BY 'weakfallback'
    HOST ANY;

-- Credentials embedded directly in table DDL. The auditor must flag these and
-- must redact the secret values in the report (never print them verbatim).
CREATE TABLE ext_feed
(
    id UInt64,
    payload String
)
ENGINE = URL('https://etl_user:s3cr3t_pw@feeds.example.com/data.json', 'JSONEachRow');

CREATE TABLE ext_s3
(
    id UInt64,
    v String
)
ENGINE = S3('https://bucket.s3.amazonaws.com/path/data.csv', 'AKIAEXAMPLEKEY123456', 'fakeSecretAccessKey1234567890', 'CSV');

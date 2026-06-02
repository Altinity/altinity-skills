-- Scenario 2: admin-equivalent grants, grant option, and broad external-source grants.
-- Note: a deliberately broad-but-grantable set is used instead of GRANT ALL so the
-- scenario applies even when the granting user does not itself hold every privilege.

DROP USER IF EXISTS sec_overprivileged;
DROP USER IF EXISTS sec_etl_sources;
DROP ROLE IF EXISTS sec_superrole;

-- Role that is effectively admin and can delegate everything it holds.
-- Expected: admin-equivalent (access management + user/role admin + broad DDL/SYSTEM)
-- combined with WITH GRANT OPTION (critical/high).
CREATE ROLE sec_superrole;
GRANT ACCESS MANAGEMENT ON *.* TO sec_superrole WITH GRANT OPTION;
GRANT CREATE USER, ALTER USER, DROP USER, CREATE ROLE, DROP ROLE, ROLE ADMIN ON *.* TO sec_superrole WITH GRANT OPTION;
GRANT SELECT, INSERT, ALTER, CREATE, DROP, TRUNCATE, SYSTEM ON *.* TO sec_superrole WITH GRANT OPTION;

CREATE USER sec_overprivileged
    IDENTIFIED WITH sha256_password BY 'Sup3r-Strong-Passphrase-1';
GRANT sec_superrole TO sec_overprivileged;

-- Non-admin ETL user with broad external-source grants plus the ability to
-- create temporary tables that table functions require.
-- Expected: broad source grants (S3/URL/FILE) + CREATE TEMPORARY TABLE -> exfiltration path.
CREATE USER sec_etl_sources
    IDENTIFIED WITH sha256_password BY 'Etl-Strong-Passphrase-2'
    HOST ANY;
GRANT S3, URL, FILE ON *.* TO sec_etl_sources;
GRANT CREATE TEMPORARY TABLE ON *.* TO sec_etl_sources;
GRANT SELECT ON `altinity-expert-clickhouse-security`.* TO sec_etl_sources;

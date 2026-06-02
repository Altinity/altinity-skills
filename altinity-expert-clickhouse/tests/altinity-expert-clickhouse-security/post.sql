-- Cleanup of global objects created by the security scenarios.
-- Runs after analysis/verification so the test does not leave insecure
-- users, roles, or policies on a shared server. Idempotent.

DROP ROW POLICY IF EXISTS sec_rp_events ON sensitive_events;
DROP VIEW IF EXISTS v_sensitive;

DROP USER IF EXISTS sec_plaintext_admin;
DROP USER IF EXISTS sec_weak_sha;
DROP USER IF EXISTS sec_overprivileged;
DROP USER IF EXISTS sec_etl_sources;
DROP USER IF EXISTS sec_definer_principal;
DROP USER IF EXISTS sec_view_reader;
DROP USER IF EXISTS sec_rowpolicy_writer;
DROP USER IF EXISTS sec_multi_auth;

DROP ROLE IF EXISTS sec_superrole;

DROP TABLE IF EXISTS ext_feed;
DROP TABLE IF EXISTS ext_s3;

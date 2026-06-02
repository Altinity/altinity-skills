-- Scenario 3: SQL SECURITY DEFINER view with an over-privileged definer, and a
-- row policy that is undermined by write privileges.

DROP VIEW IF EXISTS v_sensitive;
DROP ROW POLICY IF EXISTS sec_rp_events ON sensitive_events;
DROP USER IF EXISTS sec_definer_principal;
DROP USER IF EXISTS sec_rowpolicy_writer;
DROP USER IF EXISTS sec_view_reader;

-- No-password principal used as a view definer, but granted far more than the
-- view needs (broad SELECT on *.*, including system tables).
-- Expected: definer has excessive privileges relative to the view (high).
CREATE USER sec_definer_principal IDENTIFIED WITH no_password;
GRANT SELECT ON *.* TO sec_definer_principal;

CREATE VIEW v_sensitive
    DEFINER = sec_definer_principal SQL SECURITY DEFINER
    AS SELECT tenant, user_id, email, ssn, amount FROM sensitive_events;

-- Caller-facing reader exposed to the definer view.
CREATE USER sec_view_reader
    IDENTIFIED WITH sha256_password BY 'Reader-Strong-Passphrase-3'
    HOST ANY;
GRANT SELECT ON v_sensitive TO sec_view_reader;

-- User constrained by a row policy but ALSO granted INSERT on the same table,
-- so it can write/copy rows and defeat the read-side policy design.
-- Expected: row-policy bypass via write privilege (high/medium).
CREATE USER sec_rowpolicy_writer
    IDENTIFIED WITH sha256_password BY 'Writer-Strong-Passphrase-4'
    HOST ANY;
CREATE ROW POLICY sec_rp_events ON sensitive_events
    FOR SELECT USING tenant = 'tenant_a' TO sec_rowpolicy_writer;
GRANT SELECT, INSERT ON sensitive_events TO sec_rowpolicy_writer;

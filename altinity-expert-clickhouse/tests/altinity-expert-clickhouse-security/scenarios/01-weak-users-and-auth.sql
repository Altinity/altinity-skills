-- Scenario 1: weak authentication and broad host exposure.
-- Global objects, all prefixed sec_; dropped by post.sql.

DROP USER IF EXISTS sec_plaintext_admin;
DROP USER IF EXISTS sec_weak_sha;

-- Plaintext password stored on the server + reachable from any host.
-- Expected: high/critical (avoidable plaintext storage, broad exposure).
CREATE USER sec_plaintext_admin
    IDENTIFIED WITH plaintext_password BY 'password123'
    HOST ANY;

-- Known-weak password ('qwerty') stored as sha256, reachable from any host,
-- with no expiration policy.
-- Expected: weak-password + broad-host finding.
CREATE USER sec_weak_sha
    IDENTIFIED WITH sha256_password BY 'qwerty'
    HOST ANY;

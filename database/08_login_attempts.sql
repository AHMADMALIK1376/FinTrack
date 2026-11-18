-- =====================================================================
-- 08_login_attempts.sql  -  slow down password guessing (SEC-05)
--
-- Every failed log-in is recorded with the computer's IP address. When one
-- IP has 5 failed log-ins in the last 10 minutes, the website refuses
-- further log-ins from it until the oldest of those 5 is 10 minutes old.
-- Successful log-ins are not recorded. Rows older than a day are removed.
--
-- Run as the postgres (admin) user, after 01 - 07. Safe to run again
-- (it starts the table empty).
-- =====================================================================

DROP TABLE IF EXISTS login_attempts;

CREATE TABLE login_attempts (
    attempt_id    BIGSERIAL   PRIMARY KEY,
    ip_address    INET        NOT NULL,
    email         VARCHAR(150),            -- the e-mail that was typed, to help spot attacks; may not exist
    attempted_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- the check "failures from this IP in the last 10 minutes" reads this index only
CREATE INDEX idx_login_attempts_ip_time ON login_attempts (ip_address, attempted_at);

COMMENT ON TABLE login_attempts IS 'Failed log-ins, used to refuse an IP after 5 failures in 10 minutes (SEC-05).';

-- How long this IP must still wait, or 0 if it may try again.
CREATE OR REPLACE FUNCTION login_wait_seconds(p_ip INET, p_max_failures INT DEFAULT 5, p_window INTERVAL DEFAULT '10 minutes')
RETURNS INT
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(CEIL(EXTRACT(EPOCH FROM (MIN(attempted_at) + p_window - NOW())))::INT, 0)
    FROM (SELECT attempted_at FROM login_attempts
          WHERE ip_address = p_ip AND attempted_at > NOW() - p_window
          ORDER BY attempted_at DESC
          LIMIT p_max_failures) recent
    HAVING COUNT(*) >= p_max_failures
$$;

-- Records one failed log-in and clears out rows older than a day.
CREATE OR REPLACE PROCEDURE record_failed_login(p_ip INET, p_email VARCHAR)
LANGUAGE sql AS $$
    DELETE FROM login_attempts WHERE attempted_at < NOW() - INTERVAL '1 day';
    INSERT INTO login_attempts (ip_address, email) VALUES (p_ip, LEFT(p_email, 150));
$$;

-- the website's account may check and record attempts, nothing more
GRANT SELECT, INSERT, DELETE ON login_attempts TO fintrack_app;
GRANT USAGE ON SEQUENCE login_attempts_attempt_id_seq TO fintrack_app;
GRANT EXECUTE ON FUNCTION login_wait_seconds(INET, INT, INTERVAL) TO fintrack_app;
GRANT EXECUTE ON PROCEDURE record_failed_login(INET, VARCHAR) TO fintrack_app;

-- Signing must serialize with concurrent edits. Without a shared lock, an edit whose
-- transaction is still open when the "is it signed?" check passes could commit after the
-- signature: a result changed under a signed assessment, or a frozen library edited.
-- Two extra sessions (via dblink, over the server's own Unix socket) play the concurrent
-- writers. Each check waits for a real lock wait rather than sleeping a fixed time.
-- Needs a superuser and trust/peer auth for local socket connections (the default in the
-- official postgres images).

CREATE EXTENSION dblink;

CREATE TEMP TABLE conninfo AS
SELECT format('host=%s port=%s dbname=%s user=%s',
              trim(split_part(current_setting('unix_socket_directories'), ',', 1)),
              current_setting('port'), current_database(), current_user) AS s;
SELECT dblink_connect('a', (SELECT s FROM conninfo));
SELECT dblink_connect('b', (SELECT s FROM conninfo));
CREATE TEMP TABLE pids AS
          SELECT 'a' AS conn, p FROM dblink('a', 'SELECT pg_backend_pid()') AS t(p int)
UNION ALL SELECT 'b',         p FROM dblink('b', 'SELECT pg_backend_pid()') AS t(p int);

-- true once the session is blocked on a lock; gives up after 10 s
CREATE FUNCTION pg_temp.waits_for_lock(session TEXT) RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE
    target INT := (SELECT p FROM pids WHERE conn = session);
BEGIN
    FOR i IN 1..200 LOOP
        IF EXISTS (SELECT 1 FROM pg_locks WHERE pid = target AND NOT granted) THEN
            RETURN true;
        END IF;
        PERFORM pg_sleep(0.05);
    END LOOP;
    RETURN false;
END $$;

-- the status of an async command, then clear the connection for reuse
CREATE FUNCTION pg_temp.finish(session TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE
    result TEXT;
BEGIN
    SELECT status INTO result FROM dblink_get_result(session, false) AS r(status TEXT);
    IF result IS NULL THEN
        result := dblink_error_message(session);
    END IF;
    PERFORM * FROM dblink_get_result(session, false) AS r(status TEXT);
    RETURN result;
END $$;

-- fixtures: versions 2 and 3 for the library races; assessments A1, A2 (v1), C (v2), D (v3)
INSERT INTO library_version (framework, revision, methodology, effective_date) VALUES
    ('NIST SP 800-171', 'Rev 2', 'test v2', '2027-01-01'), ('NIST SP 800-171', 'Rev 2', 'test v3', '2027-02-01');
INSERT INTO control_family VALUES ('IA', 2, 'Identification and Authentication'), ('IA', 3, 'Identification and Authentication');
INSERT INTO requirement VALUES
    ('3.5.3', 1, 'IA', 'derived', 'MFA', 's', NULL, 5, NULL, false, false),
    ('3.5.3', 2, 'IA', 'derived', 'MFA', 's', NULL, 5, NULL, false, false),
    ('3.5.3', 3, 'IA', 'derived', 'MFA', 's', NULL, 5, NULL, false, false);
INSERT INTO assessment_objective VALUES ('3.5.3[a]', 1, '3.5.3', 'a', 't', false), ('3.5.3[b]', 1, '3.5.3', 'b', 't', false);
INSERT INTO organization (id, legal_name) VALUES ('00000000-0000-0000-0000-0000000000a1', 'Org A');
INSERT INTO assessment (id, org_id, library_version) VALUES
    ('10000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1', 1),
    ('10000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a1', 1),
    ('10000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a1', 1),
    ('10000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000a1', 2),
    ('10000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a1', 3);
INSERT INTO objective_result (assessment_id, objective_id, human_result, reviewer, reviewed_at) VALUES
    ('10000000-0000-0000-0000-0000000000a1', '3.5.3[a]', 'not_met', 'rev', now()),
    ('10000000-0000-0000-0000-0000000000a2', '3.5.3[a]', 'not_met', 'rev', now()),
    ('10000000-0000-0000-0000-0000000000a3', '3.5.3[a]', 'not_met', 'rev', now()),
    ('10000000-0000-0000-0000-0000000000a3', '3.5.3[b]', 'not_met', 'rev', now());

-- results: edit first, then sign
SELECT dblink_exec('a', 'BEGIN');
SELECT dblink_exec('a', $$UPDATE objective_result SET human_result = 'met'
                          WHERE assessment_id = '10000000-0000-0000-0000-0000000000a1'$$);
SELECT dblink_send_query('b', $$UPDATE assessment SET status = 'signed', signed_by = 'CEO', signed_at = now()
                                WHERE id = '10000000-0000-0000-0000-0000000000a1'$$);
SELECT t_eq('a signing waits for an open result edit on the same assessment', pg_temp.waits_for_lock('b'), true);
SELECT dblink_exec('a', 'COMMIT');
SELECT t_eq('... and goes through once the edit commits', pg_temp.finish('b'), 'UPDATE 1');
SELECT t_eq('the signed assessment carries the edit that committed before the signature',
            (SELECT a.status || '|' || r.human_result FROM assessment a JOIN objective_result r ON r.assessment_id = a.id
             WHERE a.id = '10000000-0000-0000-0000-0000000000a1'), 'signed|met');

-- results: sign first, then edit
SELECT dblink_exec('b', 'BEGIN');
SELECT dblink_exec('b', $$UPDATE assessment SET status = 'signed', signed_by = 'CEO', signed_at = now()
                          WHERE id = '10000000-0000-0000-0000-0000000000a2'$$);
SELECT dblink_send_query('a', $$UPDATE objective_result SET human_result = 'met'
                                WHERE assessment_id = '10000000-0000-0000-0000-0000000000a2'$$);
SELECT t_eq('a result edit waits for an in-flight signing of the same assessment', pg_temp.waits_for_lock('a'), true);
SELECT dblink_exec('b', 'COMMIT');
SELECT t_eq('... then is rejected because the assessment is now signed',
            strpos(pg_temp.finish('a'), 'assessment is signed or superseded') > 0, true);
SELECT t_eq('the signed result is unchanged',
            (SELECT human_result FROM objective_result WHERE assessment_id = '10000000-0000-0000-0000-0000000000a2'), 'not_met');

-- results: edits to an unsigned assessment don't block each other
SELECT dblink_exec('a', 'BEGIN');
SELECT dblink_exec('a', $$UPDATE objective_result SET human_result = 'met'
                          WHERE assessment_id = '10000000-0000-0000-0000-0000000000a3' AND objective_id = '3.5.3[a]'$$);
SELECT dblink_exec('b', $$SET statement_timeout = '5s'$$);
SELECT t_eq('two sessions can edit results of the same unsigned assessment at once',
            dblink_exec('b', $$UPDATE objective_result SET human_result = 'met'
                               WHERE assessment_id = '10000000-0000-0000-0000-0000000000a3' AND objective_id = '3.5.3[b]'$$),
            'UPDATE 1');
SELECT dblink_exec('b', 'RESET statement_timeout');
SELECT dblink_exec('a', 'COMMIT');

-- library: edit first, then sign
SELECT dblink_exec('a', 'BEGIN');
SELECT dblink_exec('a', $$UPDATE requirement SET sprs_weight = 3 WHERE library_version = 2 AND id = '3.5.3'$$);
SELECT dblink_send_query('b', $$UPDATE assessment SET status = 'signed', signed_by = 'CEO', signed_at = now()
                                WHERE id = '10000000-0000-0000-0000-0000000000c1'$$);
SELECT t_eq('a signing waits for an open edit to its library version', pg_temp.waits_for_lock('b'), true);
SELECT dblink_exec('a', 'COMMIT');
SELECT t_eq('... and goes through once the edit commits', pg_temp.finish('b'), 'UPDATE 1');
SELECT t_eq('the version as signed includes the edit that committed before the signature',
            (SELECT sprs_weight FROM requirement WHERE library_version = 2 AND id = '3.5.3'), 3);

-- library: sign first, then edit
SELECT dblink_exec('b', 'BEGIN');
SELECT dblink_exec('b', $$UPDATE assessment SET status = 'signed', signed_by = 'CEO', signed_at = now()
                          WHERE id = '10000000-0000-0000-0000-0000000000d1'$$);
SELECT dblink_send_query('a', $$UPDATE requirement SET sprs_weight = 3 WHERE library_version = 3 AND id = '3.5.3'$$);
SELECT t_eq('a library edit waits for an in-flight signing on that version', pg_temp.waits_for_lock('a'), true);
SELECT dblink_exec('b', 'COMMIT');
SELECT t_eq('... then is rejected because the version is now frozen',
            strpos(pg_temp.finish('a'), 'library version is frozen') > 0, true);
SELECT t_eq('the frozen version is unchanged',
            (SELECT sprs_weight FROM requirement WHERE library_version = 3 AND id = '3.5.3'), 5);

SELECT dblink_disconnect('a');
SELECT dblink_disconnect('b');

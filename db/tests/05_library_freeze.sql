-- A library version freezes once any assessment on it is signed or superseded: its families,
-- requirements, objectives, rules, evidence methods and the version row itself can't be
-- inserted, updated or deleted. Other versions stay editable.

INSERT INTO library_version (framework, revision, methodology, effective_date)
VALUES ('NIST SP 800-171', 'Rev 2', 'test v2', '2027-01-01');
SELECT t_eq('fixture: the second version has id 2', (SELECT max(id) FROM library_version), 2);

SELECT t_ok('TRUNCATE of library tables is allowed while nothing is signed',
    $$INSERT INTO check_rule VALUES ('TMP', 1, 't', 'graph', '{}', NULL); TRUNCATE check_rule CASCADE$$);

INSERT INTO control_family VALUES ('CA', 1, 'Security Assessment'), ('PL', 1, 'Planning'),
                                  ('IA', 2, 'Identification and Authentication'), ('SC', 2, 'System and Communications Protection');
INSERT INTO requirement VALUES
    ('3.5.3', 1, 'IA', 'derived', 'MFA', 's', NULL, 5, NULL, false, false),
    ('3.5.3', 2, 'IA', 'derived', 'MFA', 's', NULL, 3, NULL, false, false);
INSERT INTO assessment_objective VALUES ('3.5.3[a]', 1, '3.5.3', 'a', 't', false), ('3.5.3[a]', 2, '3.5.3', 'a', 't', false);
INSERT INTO check_rule VALUES
    ('IA-MFA', 1, 'MFA', 'graph', '{"min": 0.9}', NULL),
    ('IA-MFA', 2, 'MFA', 'graph', '{"min": 1.0}', NULL),
    ('MOVE-ME', 2, 'm', 'graph', '{}', NULL);
INSERT INTO evidence_method (id, library_version, objective_id, method_type, rule_id) VALUES
    (1, 1, '3.5.3[a]', 'automated_check', 'IA-MFA'), (2, 2, '3.5.3[a]', 'automated_check', 'IA-MFA');
INSERT INTO organization (id, legal_name) VALUES ('00000000-0000-0000-0000-0000000000a1', 'Org A');
INSERT INTO assessment (id, org_id, library_version) VALUES
    ('10000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 1),
    ('10000000-0000-0000-0000-00000000000c', '00000000-0000-0000-0000-0000000000a1', 2);

SELECT t_ok('before signing, version 1 is editable',
    $$UPDATE requirement SET plain_english = 'typo fixed' WHERE library_version = 1 AND id = '3.5.3'$$);

UPDATE assessment SET status = 'signed', signed_by = 'CEO', signed_at = now()
WHERE id = '10000000-0000-0000-0000-00000000000a';

-- every library table, every operation, for the frozen version
SELECT t_raises('frozen: rename a family',
    $$UPDATE control_family SET name = 'renamed' WHERE library_version = 1 AND code = 'IA'$$,
    'UPDATE on control_family rejected: library version is frozen');
SELECT t_raises('frozen: re-code a family',
    $$UPDATE control_family SET code = 'IAX' WHERE library_version = 1 AND code = 'IA'$$,
    'UPDATE on control_family rejected');
SELECT t_raises('frozen: add a family',
    $$INSERT INTO control_family VALUES ('RA', 1, 'Risk Assessment')$$, 'INSERT on control_family rejected');
SELECT t_raises('frozen: delete an unused family',
    $$DELETE FROM control_family WHERE library_version = 1 AND code = 'PL'$$, 'DELETE on control_family rejected');
SELECT t_raises('frozen: change a requirement weight',
    $$UPDATE requirement SET sprs_weight = 3 WHERE library_version = 1 AND id = '3.5.3'$$,
    'UPDATE on requirement rejected');
SELECT t_raises('frozen: add a requirement',
    $$INSERT INTO requirement VALUES ('3.1.1', 1, 'IA', 'basic', 'x', 'x', NULL, 5, NULL, false, false)$$,
    'INSERT on requirement rejected');
SELECT t_raises('frozen: add an objective (would make a signed requirement unreviewed)',
    $$INSERT INTO assessment_objective VALUES ('3.5.3[b]', 1, '3.5.3', 'b', 't', false)$$,
    'INSERT on assessment_objective rejected');
SELECT t_raises('frozen: edit an objective',
    $$UPDATE assessment_objective SET text = 'changed' WHERE library_version = 1$$,
    'UPDATE on assessment_objective rejected');
SELECT t_raises('frozen: change rule logic',
    $$UPDATE check_rule SET logic = '{"min": 0.5}' WHERE library_version = 1 AND id = 'IA-MFA'$$,
    'UPDATE on check_rule rejected');
SELECT t_raises('frozen: add a rule',
    $$INSERT INTO check_rule VALUES ('NEW', 1, 'n', 'graph', '{}', NULL)$$, 'INSERT on check_rule rejected');
SELECT t_raises('frozen: delete an evidence method',
    $$DELETE FROM evidence_method WHERE id = 1$$, 'DELETE on evidence_method rejected');
SELECT t_raises('frozen: edit an evidence method',
    $$UPDATE evidence_method SET assessor_guidance = 'x' WHERE id = 1$$, 'UPDATE on evidence_method rejected');
SELECT t_raises('frozen: edit the library_version row',
    $$UPDATE library_version SET methodology = 'renamed' WHERE id = 1$$, 'UPDATE on library_version rejected');
SELECT t_raises('frozen: move a row from an unfrozen version into the frozen one',
    $$UPDATE check_rule SET library_version = 1 WHERE library_version = 2 AND id = 'MOVE-ME'$$,
    'UPDATE on check_rule rejected');

SELECT t_eq('frozen version 1 is exactly as signed (pre-signing fix kept)',
            (SELECT r.sprs_weight || '|' || r.plain_english || '|' || (c.logic ->> 'min') || '|'
                    || (SELECT count(*) FROM assessment_objective WHERE library_version = 1) || '|'
                    || (SELECT methodology FROM library_version WHERE id = 1) || '|'
                    || (SELECT name FROM control_family WHERE library_version = 1 AND code = 'IA')
             FROM requirement r JOIN check_rule c ON c.library_version = r.library_version AND c.id = 'IA-MFA'
             WHERE r.library_version = 1 AND r.id = '3.5.3'),
            '5|typo fixed|0.9|1|DoD Assessment Methodology v1.2.1|Identification and Authentication');

-- the unfrozen version is unaffected, even where codes are shared
SELECT t_ok('unfrozen: change a requirement weight',
    $$UPDATE requirement SET sprs_weight = 5 WHERE library_version = 2$$);
SELECT t_ok('unfrozen: add an objective',
    $$INSERT INTO assessment_objective VALUES ('3.5.3[b]', 2, '3.5.3', 'b', 't', false)$$);
SELECT t_ok('unfrozen: change rule logic and delete a rule',
    $$UPDATE check_rule SET logic = '{"min": 0.95}' WHERE library_version = 2 AND id = 'IA-MFA';
      DELETE FROM check_rule WHERE library_version = 2 AND id = 'MOVE-ME'$$);
SELECT t_ok('unfrozen: rename a family whose code is frozen in version 1',
    $$UPDATE control_family SET name = 'Identification & Authentication' WHERE library_version = 2 AND code = 'IA'$$);
SELECT t_ok('unfrozen: add and delete families',
    $$INSERT INTO control_family VALUES ('RA', 2, 'Risk Assessment');
      DELETE FROM control_family WHERE library_version = 2 AND code = 'SC'$$);
SELECT t_ok('unfrozen: edit the library_version row',
    $$UPDATE library_version SET notes = 'draft' WHERE id = 2$$);
SELECT t_ok('new versions can still be added and filled',
    $$INSERT INTO library_version (framework, revision, methodology, effective_date)
          VALUES ('NIST SP 800-171', 'Rev 2', 'test v3', '2028-01-01');
      INSERT INTO control_family VALUES ('IA', 3, 'Identification and Authentication')$$);

-- TRUNCATE once anything is signed
SELECT t_raises('library tables cannot be truncated',
    $$TRUNCATE check_rule CASCADE$$, 'TRUNCATE on check_rule rejected');
SELECT t_raises('families cannot be truncated',
    $$TRUNCATE control_family CASCADE$$, 'TRUNCATE on control_family rejected');
SELECT t_raises('requirements cannot be truncated',
    $$TRUNCATE requirement CASCADE$$, 'TRUNCATE on requirement rejected');

-- superseded freezes too
UPDATE assessment SET status = 'superseded' WHERE id = '10000000-0000-0000-0000-00000000000c';
SELECT t_raises('a version whose only assessment is superseded is frozen too',
    $$UPDATE check_rule SET logic = '{}' WHERE library_version = 2$$, 'UPDATE on check_rule rejected');
SELECT t_raises('... including its families',
    $$UPDATE control_family SET name = 'again' WHERE library_version = 2 AND code = 'RA'$$,
    'UPDATE on control_family rejected');

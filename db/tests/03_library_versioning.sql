-- Library rows are keyed by (library_version, id): the same IDs coexist across versions, and
-- every reference must stay inside one version. Also covers the example seed and the trigger
-- that fills library_version in from the assessment.

SELECT t_eq('the schema seed creates version 1 for DoD Assessment Methodology v1.2.1',
            (SELECT methodology FROM library_version WHERE id = 1), 'DoD Assessment Methodology v1.2.1');
SELECT t_eq('the seed attaches its families (IA, SC) to version 1',
            (SELECT string_agg(code, ',' ORDER BY code) FROM control_family WHERE library_version = 1), 'IA,SC');

INSERT INTO library_version (framework, revision, methodology, effective_date)
VALUES ('NIST SP 800-171', 'Rev 2', 'test v2', '2027-01-01');
SELECT t_eq('fixture: the second version has id 2', (SELECT max(id) FROM library_version), 2);

-- the same IDs in two versions
SELECT t_ok('the same family code can exist in two versions with different names',
    $$INSERT INTO control_family VALUES ('IA', 2, 'Identification & Authentication (v2 wording)'),
                                        ('SC', 2, 'System and Communications Protection')$$);
SELECT t_ok('the same requirement ID can exist in two versions with different weights',
    $$INSERT INTO requirement VALUES
        ('3.5.3',   1, 'IA', 'derived', 'MFA',  's', NULL, 5, NULL, false, false),
        ('3.13.11', 1, 'SC', 'derived', 'FIPS', 's', NULL, 5, NULL, false, false),
        ('3.5.3',   2, 'IA', 'derived', 'MFA',  's', NULL, 3, NULL, false, false)$$);
SELECT t_ok('the same objective ID can exist in two versions',
    $$INSERT INTO assessment_objective VALUES
        ('3.5.3[a]', 1, '3.5.3', 'a', 't', false), ('3.5.3[b]', 1, '3.5.3', 'b', 't', false),
        ('3.13.11[a]', 1, '3.13.11', 'a', 't', false), ('3.5.3[a]', 2, '3.5.3', 'a', 't v2', false)$$);
SELECT t_ok('the same check rule ID can exist in two versions with different logic',
    $$INSERT INTO check_rule VALUES
        ('IA-MFA-ALL-USERS', 1, 'MFA for all users', 'graph', '{"min_coverage": 0.9}', 'Entra ID P1'),
        ('IA-MFA-ALL-USERS', 2, 'MFA for all users', 'graph', '{"min_coverage": 1.0}', 'Entra ID P1'),
        ('IA-MFA-ADMINS',    1, 'MFA for admins',    'graph', '{"roles": "privileged"}', NULL)$$);

-- duplicates within a version
SELECT t_raises('duplicate family within a version',
    $$INSERT INTO control_family VALUES ('IA', 1, 'dup')$$, 'control_family_pkey');
SELECT t_raises('duplicate requirement within a version',
    $$INSERT INTO requirement VALUES ('3.5.3', 1, 'IA', 'derived', 'dup', 'x', NULL, 5, NULL, false, false)$$,
    'requirement_pkey');
SELECT t_raises('duplicate check rule within a version',
    $$INSERT INTO check_rule VALUES ('IA-MFA-ALL-USERS', 1, 'dup', 'graph', '{}', NULL)$$, 'check_rule_pkey');
SELECT t_raises('a check rule needs an existing library version',
    $$INSERT INTO check_rule VALUES ('X', 99, 'x', 'graph', '{}', NULL)$$, 'check_rule_library_version_fkey');

-- references must stay inside one version
INSERT INTO control_family VALUES ('PL', 1, 'Planning');
SELECT t_raises('a v2 requirement cannot use a family that only exists in v1',
    $$INSERT INTO requirement VALUES ('3.0.1', 2, 'PL', 'basic', 'x', 'x', NULL, 1, NULL, true, false)$$,
    'requirement_library_version_family_code_fkey');
SELECT t_raises('a v2 objective cannot point at a requirement that only exists in v1',
    $$INSERT INTO assessment_objective VALUES ('3.13.11[a]', 2, '3.13.11', 'a', 't', false)$$,
    'assessment_objective_library_version_requirement_id_fkey');
SELECT t_raises('an evidence method cannot use an objective from another version',
    $$INSERT INTO evidence_method (library_version, objective_id, method_type) VALUES (2, '3.13.11[a]', 'document')$$,
    'evidence_method_library_version_objective_id_fkey');
SELECT t_raises('a v2 evidence method cannot use a rule that only exists in v1',
    $$INSERT INTO evidence_method (library_version, objective_id, method_type, rule_id)
      VALUES (2, '3.5.3[a]', 'automated_check', 'IA-MFA-ADMINS')$$,
    'evidence_method_library_version_rule_id_fkey');
SELECT t_ok('evidence methods resolve rules in their own version, and manual methods need none',
    $$INSERT INTO evidence_method (library_version, objective_id, method_type, rule_id) VALUES
        (1, '3.5.3[a]', 'automated_check', 'IA-MFA-ALL-USERS'),
        (2, '3.5.3[a]', 'automated_check', 'IA-MFA-ALL-USERS'),
        (2, '3.5.3[a]', 'interview', NULL)$$);
SELECT t_eq('each version''s method sees its own rule logic',
            (SELECT string_agg(m.library_version || '=' || (r.logic ->> 'min_coverage'), ',' ORDER BY m.library_version)
             FROM evidence_method m JOIN check_rule r ON r.library_version = m.library_version AND r.id = m.rule_id),
            '1=0.9,2=1.0');
SELECT t_raises('a rule still used by an evidence method cannot be deleted',
    $$DELETE FROM check_rule WHERE library_version = 1 AND id = 'IA-MFA-ALL-USERS'$$,
    'evidence_method_library_version_rule_id_fkey');

-- per-assessment rows must use the assessment's own version
INSERT INTO organization (id, legal_name) VALUES ('00000000-0000-0000-0000-0000000000a1', 'Org A');
INSERT INTO assessment (id, org_id, library_version) VALUES
    ('10000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 1),
    ('10000000-0000-0000-0000-00000000000c', '00000000-0000-0000-0000-0000000000a1', 2);

SELECT t_raises('a result tagged with a version other than its assessment''s',
    $$INSERT INTO objective_result (assessment_id, library_version, objective_id)
      VALUES ('10000000-0000-0000-0000-00000000000a', 2, '3.5.3[a]')$$,
    'objective_result_assessment_id_library_version_fkey');
SELECT t_raises('a result for an objective that does not exist in the assessment''s version',
    $$INSERT INTO objective_result (assessment_id, objective_id)
      VALUES ('10000000-0000-0000-0000-00000000000c', '3.13.11[a]')$$,
    'objective_result_library_version_objective_id_fkey');
SELECT t_raises('an SSP section tagged with the wrong version',
    $$INSERT INTO ssp_narrative (assessment_id, library_version, requirement_id)
      VALUES ('10000000-0000-0000-0000-00000000000a', 2, '3.5.3')$$,
    'ssp_narrative_assessment_id_library_version_fkey');
SELECT t_raises('a POA&M item for a requirement that does not exist in the assessment''s version',
    $$INSERT INTO poam_item (assessment_id, requirement_id, weakness, remediation)
      VALUES ('10000000-0000-0000-0000-00000000000c', '3.13.11', 'w', 'r')$$,
    'poam_item_library_version_requirement_id_fkey');

-- library_version is filled in from the assessment when omitted
INSERT INTO objective_result (assessment_id, objective_id) VALUES
    ('10000000-0000-0000-0000-00000000000a', '3.5.3[a]'), ('10000000-0000-0000-0000-00000000000c', '3.5.3[a]');
INSERT INTO ssp_narrative (assessment_id, requirement_id) VALUES
    ('10000000-0000-0000-0000-00000000000a', '3.5.3'), ('10000000-0000-0000-0000-00000000000c', '3.5.3');
INSERT INTO poam_item (assessment_id, requirement_id, weakness, remediation) VALUES
    ('10000000-0000-0000-0000-00000000000a', '3.13.11', 'w', 'r'), ('10000000-0000-0000-0000-00000000000c', '3.5.3', 'w', 'r');
SELECT t_eq('objective_result gets the assessment''s version when omitted',
            (SELECT string_agg(library_version::text, ',' ORDER BY assessment_id) FROM objective_result), '1,2');
SELECT t_eq('ssp_narrative gets the assessment''s version when omitted',
            (SELECT string_agg(library_version::text, ',' ORDER BY assessment_id) FROM ssp_narrative), '1,2');
SELECT t_eq('poam_item gets the assessment''s version when omitted',
            (SELECT string_agg(library_version::text, ',' ORDER BY assessment_id) FROM poam_item), '1,2');
SELECT t_ok('an explicit NULL version is filled in too',
    $$INSERT INTO objective_result (assessment_id, library_version, objective_id)
      VALUES ('10000000-0000-0000-0000-00000000000a', NULL, '3.5.3[b]')$$);
SELECT t_raises('an unknown assessment gets a clear error, not a NOT NULL one',
    $$INSERT INTO objective_result (assessment_id, objective_id)
      VALUES ('99999999-9999-9999-9999-999999999999', '3.5.3[a]')$$,
    'assessment 99999999-9999-9999-9999-999999999999 does not exist');
SELECT t_raises('the fill-in is insert-only: an update cannot set the version to NULL',
    $$UPDATE objective_result SET library_version = NULL WHERE objective_id = '3.5.3[b]'$$,
    'violates not-null constraint');
SELECT t_raises('an assessment''s version cannot change once it has results',
    $$UPDATE assessment SET library_version = 2 WHERE id = '10000000-0000-0000-0000-00000000000a'$$,
    'objective_result_assessment_id_library_version_fkey');

-- the scoring view reads each assessment's own version
SELECT t_eq('a v1 assessment sees v1 requirements and weights',
            (SELECT string_agg(requirement_id || ':' || sprs_weight, ',' ORDER BY requirement_id)
             FROM requirement_status WHERE assessment_id = '10000000-0000-0000-0000-00000000000a'),
            '3.13.11:5,3.5.3:5');
SELECT t_eq('a v2 assessment sees only v2 requirements and weights',
            (SELECT string_agg(requirement_id || ':' || sprs_weight, ',' ORDER BY requirement_id)
             FROM requirement_status WHERE assessment_id = '10000000-0000-0000-0000-00000000000c'),
            '3.5.3:3');

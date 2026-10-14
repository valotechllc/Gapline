-- requirement_status: a requirement is 'met' only when every one of its objectives has a human
-- result and all are met or N/A. Anything less is 'unreviewed', and no requirement may drop out
-- of the view (a missing requirement is a missed deduction and an inflated score).

INSERT INTO control_family VALUES ('CA', 1, 'Security Assessment');
INSERT INTO requirement VALUES
    ('3.5.3',   1, 'IA', 'derived', 'MFA',  's', NULL, 5,    NULL, false, false),
    ('3.13.11', 1, 'SC', 'derived', 'FIPS', 's', NULL, 5,    NULL, false, false),
    ('3.12.4',  1, 'CA', 'derived', 'SSP',  's', NULL, NULL, NULL, false, true),
    ('3.13.1',  1, 'SC', 'derived', 'No objectives loaded', 's', NULL, 5, NULL, false, false);
INSERT INTO assessment_objective VALUES
    ('3.5.3[a]',   1, '3.5.3',   'a', 't', false),
    ('3.5.3[b]',   1, '3.5.3',   'b', 't', false),
    ('3.13.11[a]', 1, '3.13.11', 'a', 't', false),
    ('3.12.4[a]',  1, '3.12.4',  'a', 't', false);
INSERT INTO organization (id, legal_name) VALUES ('00000000-0000-0000-0000-0000000000a1', 'Org A');
INSERT INTO assessment (id, org_id, library_version) VALUES
    ('10000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 1),
    ('10000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 1);

CREATE TEMP VIEW a_status AS
    SELECT requirement_id, status, objectives_reviewed || '/' || objectives_total AS reviewed
    FROM requirement_status WHERE assessment_id = '10000000-0000-0000-0000-00000000000a';

SELECT t_eq('every library requirement is in the view before any review',
            (SELECT count(*) FROM a_status), 4);
SELECT t_eq('a requirement with no results shows as unreviewed, not missing',
            (SELECT status FROM a_status WHERE requirement_id = '3.13.11'), 'unreviewed');

INSERT INTO objective_result (assessment_id, objective_id, human_result, reviewer, reviewed_at)
VALUES ('10000000-0000-0000-0000-00000000000a', '3.5.3[a]', 'met', 'rev', now());
SELECT t_eq('a half-reviewed requirement is unreviewed, not met',
            (SELECT status FROM a_status WHERE requirement_id = '3.5.3'), 'unreviewed');
SELECT t_eq('reviewed / total objectives are counted',
            (SELECT reviewed FROM a_status WHERE requirement_id = '3.5.3'), '1/2');

INSERT INTO objective_result (assessment_id, objective_id, ai_result, ai_model)
VALUES ('10000000-0000-0000-0000-00000000000a', '3.13.11[a]', 'met', 'some-model');
SELECT t_eq('an AI result alone does not count as reviewed',
            (SELECT status FROM a_status WHERE requirement_id = '3.13.11'), 'unreviewed');

INSERT INTO objective_result (assessment_id, objective_id, human_result, reviewer, reviewed_at) VALUES
    ('10000000-0000-0000-0000-00000000000a', '3.5.3[b]',  'not_applicable', 'rev', now()),
    ('10000000-0000-0000-0000-00000000000a', '3.12.4[a]', 'met',            'rev', now());
UPDATE objective_result SET human_result = 'not_met', reviewer = 'rev', reviewed_at = now()
WHERE assessment_id = '10000000-0000-0000-0000-00000000000a' AND objective_id = '3.13.11[a]';

SELECT t_eq('met + not_applicable objectives make the requirement met',
            (SELECT status FROM a_status WHERE requirement_id = '3.5.3'), 'met');
SELECT t_eq('one not_met objective makes the requirement not_met',
            (SELECT status FROM a_status WHERE requirement_id = '3.13.11'), 'not_met');
SELECT t_eq('a blocks_scoring requirement (3.12.4) is scored like any other',
            (SELECT status FROM a_status WHERE requirement_id = '3.12.4'), 'met');
SELECT t_eq('a requirement with no objectives loaded fails closed as unreviewed',
            (SELECT status FROM a_status WHERE requirement_id = '3.13.1'), 'unreviewed');
SELECT t_eq('another assessment on the same version is unaffected (all unreviewed)',
            (SELECT count(*) FROM requirement_status
             WHERE assessment_id = '10000000-0000-0000-0000-00000000000b' AND status = 'unreviewed'), 4);

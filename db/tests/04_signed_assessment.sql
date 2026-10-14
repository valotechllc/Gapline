-- Signing: a signed assessment's results and evidence links are locked; the assessment itself
-- can only move signed -> superseded; it can't be created already signed, deleted, or emptied
-- with TRUNCATE.

INSERT INTO requirement VALUES ('3.5.3', 1, 'IA', 'derived', 'MFA', 's', NULL, 5, NULL, false, false);
INSERT INTO assessment_objective VALUES ('3.5.3[a]', 1, '3.5.3', 'a', 't', false), ('3.5.3[b]', 1, '3.5.3', 'b', 't', false);
INSERT INTO organization (id, legal_name) VALUES ('00000000-0000-0000-0000-0000000000a1', 'Org A');

SELECT t_raises('an assessment cannot be created already signed',
    $$INSERT INTO assessment (org_id, library_version, status, signed_by, signed_at)
      VALUES ('00000000-0000-0000-0000-0000000000a1', 1, 'signed', 'CEO', now())$$,
    'create it unsigned, then sign it by update');

INSERT INTO assessment (id, org_id, library_version, scope_notes) VALUES
    ('10000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 1, 'scope A'),
    ('10000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 1, 'scope B');

SELECT t_ok('TRUNCATE of results is allowed while nothing is signed',
    $$TRUNCATE objective_result CASCADE$$);

INSERT INTO objective_result (assessment_id, objective_id, human_result, reviewer, reviewed_at)
VALUES ('10000000-0000-0000-0000-00000000000a', '3.5.3[a]', 'not_met', 'rev', now());
INSERT INTO evidence_item (id, assessment_id, source, file_uri, sha256)
VALUES ('20000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-00000000000a', 'graph', 's3://a/1', repeat('a', 64));
INSERT INTO objective_evidence VALUES
    ('10000000-0000-0000-0000-00000000000a', '3.5.3[a]', '20000000-0000-0000-0000-00000000000a');

SELECT t_ok('signing with signer and date succeeds',
    $$UPDATE assessment SET status = 'signed', signed_by = 'CEO', signed_at = now()
      WHERE id = '10000000-0000-0000-0000-00000000000a'$$);

-- results and evidence links are locked
SELECT t_raises('a signed result cannot be changed',
    $$UPDATE objective_result SET human_result = 'met' WHERE assessment_id = '10000000-0000-0000-0000-00000000000a'$$,
    'UPDATE on objective_result rejected: assessment is signed or superseded');
SELECT t_raises('a signed result cannot be deleted',
    $$DELETE FROM objective_result WHERE assessment_id = '10000000-0000-0000-0000-00000000000a'$$,
    'DELETE on objective_result rejected');
SELECT t_raises('no new results can be added to a signed assessment',
    $$INSERT INTO objective_result (assessment_id, objective_id) VALUES ('10000000-0000-0000-0000-00000000000a', '3.5.3[b]')$$,
    'INSERT on objective_result rejected');
SELECT t_raises('a result cannot be moved out of a signed assessment',
    $$UPDATE objective_result SET assessment_id = '10000000-0000-0000-0000-00000000000b'
      WHERE assessment_id = '10000000-0000-0000-0000-00000000000a'$$,
    'UPDATE on objective_result rejected');
SELECT t_raises('an evidence link cannot be removed from a signed assessment',
    $$DELETE FROM objective_evidence WHERE assessment_id = '10000000-0000-0000-0000-00000000000a'$$,
    'DELETE on objective_evidence rejected');

-- the assessment row itself
SELECT t_raises('a signed assessment cannot be un-signed',
    $$UPDATE assessment SET status = 'in_progress' WHERE id = '10000000-0000-0000-0000-00000000000a'$$,
    'the only allowed change is signed -> superseded');
SELECT t_raises('a signed assessment cannot go back to in_review',
    $$UPDATE assessment SET status = 'in_review' WHERE id = '10000000-0000-0000-0000-00000000000a'$$,
    'the only allowed change is signed -> superseded');
SELECT t_raises('a signed assessment''s scope cannot be edited',
    $$UPDATE assessment SET scope_notes = 'quietly narrowed' WHERE id = '10000000-0000-0000-0000-00000000000a'$$,
    'the only allowed change is signed -> superseded');
SELECT t_raises('a signed assessment''s signer cannot be changed',
    $$UPDATE assessment SET signed_by = 'Someone else' WHERE id = '10000000-0000-0000-0000-00000000000a'$$,
    'the only allowed change is signed -> superseded');
SELECT t_raises('superseding cannot carry other edits with it',
    $$UPDATE assessment SET status = 'superseded', scope_notes = 'edited on the way out'
      WHERE id = '10000000-0000-0000-0000-00000000000a'$$,
    'the only allowed change is signed -> superseded');
SELECT t_raises('a signed assessment cannot be deleted',
    $$DELETE FROM assessment WHERE id = '10000000-0000-0000-0000-00000000000a'$$,
    'DELETE on assessment');
SELECT t_ok('no-op updates of a signed assessment pass (whole-row saves)',
    $$UPDATE assessment SET status = status, scope_notes = 'scope A' WHERE id = '10000000-0000-0000-0000-00000000000a'$$);

-- TRUNCATE once anything is signed
SELECT t_raises('results cannot be truncated',
    $$TRUNCATE objective_result CASCADE$$, 'signed or superseded assessments exist');
SELECT t_raises('evidence links cannot be truncated',
    $$TRUNCATE objective_evidence$$, 'signed or superseded assessments exist');
SELECT t_raises('assessments cannot be truncated',
    $$TRUNCATE assessment CASCADE$$, 'TRUNCATE on assessment rejected');

-- superseding
SELECT t_ok('signed -> superseded is allowed',
    $$UPDATE assessment SET status = 'superseded' WHERE id = '10000000-0000-0000-0000-00000000000a'$$);
SELECT t_raises('superseded is final: cannot be re-signed',
    $$UPDATE assessment SET status = 'signed' WHERE id = '10000000-0000-0000-0000-00000000000a'$$,
    'it is superseded');
SELECT t_raises('superseded is final: cannot be reopened',
    $$UPDATE assessment SET status = 'in_progress' WHERE id = '10000000-0000-0000-0000-00000000000a'$$,
    'it is superseded');
SELECT t_raises('a superseded assessment cannot be deleted',
    $$DELETE FROM assessment WHERE id = '10000000-0000-0000-0000-00000000000a'$$,
    'it is superseded');
SELECT t_raises('a superseded assessment''s results stay locked',
    $$UPDATE objective_result SET human_result = 'met' WHERE assessment_id = '10000000-0000-0000-0000-00000000000a'$$,
    'assessment is signed or superseded');

-- unsigned assessments are unaffected
SELECT t_ok('an unsigned assessment can be edited',
    $$UPDATE assessment SET scope_notes = 'scope B v2' WHERE id = '10000000-0000-0000-0000-00000000000b'$$);
SELECT t_ok('an unsigned assessment''s results can be added, changed and removed',
    $$INSERT INTO objective_result (assessment_id, objective_id, ai_result, ai_model)
          VALUES ('10000000-0000-0000-0000-00000000000b', '3.5.3[a]', 'met', 'some-model');
      UPDATE objective_result SET human_result = 'met', reviewer = 'r', reviewed_at = now()
          WHERE assessment_id = '10000000-0000-0000-0000-00000000000b';
      DELETE FROM objective_result WHERE assessment_id = '10000000-0000-0000-0000-00000000000b'$$);
SELECT t_ok('an unsigned assessment can be superseded directly',
    $$UPDATE assessment SET status = 'superseded' WHERE id = '10000000-0000-0000-0000-00000000000b'$$);

SELECT t_eq('the superseded assessment kept its signer, scope and result',
            (SELECT status || '|' || signed_by || '|' || scope_notes FROM assessment
             WHERE id = '10000000-0000-0000-0000-00000000000a')
            || '|' || (SELECT human_result FROM objective_result
                       WHERE assessment_id = '10000000-0000-0000-0000-00000000000a'),
            'superseded|CEO|scope A|not_met');

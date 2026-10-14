-- Row-level integrity: weights, reviewer and model attribution, signer, evidence hashing and
-- raw bytes, evidence pinned to its own assessment, and append-only evidence.

INSERT INTO control_family VALUES ('CA', 1, 'Security Assessment');
INSERT INTO requirement VALUES ('3.5.3', 1, 'IA', 'derived', 'MFA', 's', NULL, 5, NULL, false, false);
INSERT INTO assessment_objective VALUES ('3.5.3[a]', 1, '3.5.3', 'a', 't', false);
INSERT INTO organization (id, legal_name) VALUES ('00000000-0000-0000-0000-0000000000a1', 'Org A');
INSERT INTO assessment (id, org_id, library_version) VALUES
    ('10000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 1),
    ('10000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 1);

-- SPRS weight
SELECT t_raises('weight NULL is rejected on a normal requirement',
    $$INSERT INTO requirement VALUES ('9.9.1', 1, 'IA', 'basic', 'x', 'x', NULL, NULL, NULL, true, false)$$,
    'requirement_check');
SELECT t_raises('weight outside 1/3/5 is rejected',
    $$INSERT INTO requirement VALUES ('9.9.2', 1, 'IA', 'basic', 'x', 'x', NULL, 2, NULL, true, false)$$,
    'requirement_check');
SELECT t_ok('weight NULL is allowed on a blocks_scoring requirement (3.12.4)',
    $$INSERT INTO requirement VALUES ('3.12.4', 1, 'CA', 'derived', 'SSP', 's', NULL, NULL, NULL, false, true)$$);

-- result attribution
SELECT t_raises('human_result needs a reviewer and timestamp',
    $$INSERT INTO objective_result (assessment_id, objective_id, human_result)
      VALUES ('10000000-0000-0000-0000-00000000000a', '3.5.3[a]', 'met')$$,
    'objective_result_check');
SELECT t_raises('ai_result needs ai_model',
    $$INSERT INTO objective_result (assessment_id, objective_id, ai_result)
      VALUES ('10000000-0000-0000-0000-00000000000a', '3.5.3[a]', 'met')$$,
    'objective_result_check');
SELECT t_ok('fully attributed results are accepted',
    $$INSERT INTO objective_result (assessment_id, objective_id, ai_result, ai_model, human_result, reviewer, reviewed_at)
      VALUES ('10000000-0000-0000-0000-00000000000a', '3.5.3[a]', 'met', 'some-model', 'met', 'rev', now())$$);

-- signing
SELECT t_raises('signed needs signed_by and signed_at',
    $$UPDATE assessment SET status = 'signed' WHERE id = '10000000-0000-0000-0000-00000000000b'$$,
    'assessment_check');

-- evidence
SELECT t_raises('sha256 must be 64 lowercase hex characters',
    $$INSERT INTO evidence_item (assessment_id, source, file_uri, sha256)
      VALUES ('10000000-0000-0000-0000-00000000000a', 'graph', 's3://a/1', 'not-a-hash')$$,
    'evidence_item_sha256_check');
SELECT t_raises('API evidence must keep its raw bytes (file_uri), not just a JSONB payload',
    $$INSERT INTO evidence_item (assessment_id, source, payload, sha256)
      VALUES ('10000000-0000-0000-0000-00000000000a', 'graph', '{}', repeat('a', 64))$$,
    'evidence_item_check');
SELECT t_ok('an interview answer may be payload-only',
    $$INSERT INTO evidence_item (assessment_id, source, payload, sha256)
      VALUES ('10000000-0000-0000-0000-00000000000a', 'interview', '{"answer": "yes"}', repeat('a', 64))$$);

INSERT INTO evidence_item (id, assessment_id, source, file_uri, sha256) VALUES
    ('20000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-00000000000a', 'graph', 's3://a/2', repeat('b', 64)),
    ('20000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-00000000000b', 'graph', 's3://b/1', repeat('c', 64));

SELECT t_raises('evidence from another assessment cannot back this objective',
    $$INSERT INTO objective_evidence VALUES
      ('10000000-0000-0000-0000-00000000000a', '3.5.3[a]', '20000000-0000-0000-0000-00000000000b')$$,
    'objective_evidence_evidence_id_assessment_id_fkey');
SELECT t_ok('evidence from the same assessment can',
    $$INSERT INTO objective_evidence VALUES
      ('10000000-0000-0000-0000-00000000000a', '3.5.3[a]', '20000000-0000-0000-0000-00000000000a')$$);

SELECT t_raises('evidence cannot be updated',
    $$UPDATE evidence_item SET payload = '{"tampered": true}'$$, 'evidence_item is append-only');
SELECT t_raises('evidence cannot be deleted',
    $$DELETE FROM evidence_item$$, 'evidence_item is append-only');
SELECT t_raises('evidence cannot be truncated',
    $$TRUNCATE evidence_item CASCADE$$, 'evidence_item is append-only');
SELECT t_eq('all evidence rows are still there', (SELECT count(*) FROM evidence_item), 3);

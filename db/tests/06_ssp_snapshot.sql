-- Signing copies the SSP into ssp_snapshot and writes one ssp_snapshot_digest row. Both are
-- append-only and written only by the signing trigger; ssp_narrative stays editable.
--
-- Expected hashes were computed outside Postgres, so these tests check the documented format,
-- not just that the database agrees with itself:
--   h() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
--   h $'MFA — enforced for all users (café ✓)'    -> ea9ae7a5...
--   h $'SSP v1.0\n\tApproved 2026-10-01'                         -> 5698ead5...
--   h ''                                                          -> e3b0c442...
--   printf '%s\t%s\n' 3.5.3 <h1> 3.12.4 <h2> 3.13.11 - 3.1.1 <h3> | LC_ALL=C sort | sha256sum
--                                                                 -> d7f78f80...

INSERT INTO control_family VALUES ('CA', 1, 'Security Assessment'), ('AC', 1, 'Access Control');
INSERT INTO requirement VALUES
    ('3.5.3',   1, 'IA', 'derived', 'MFA',    's', NULL, 5,    NULL, false, false),
    ('3.12.4',  1, 'CA', 'derived', 'SSP',    's', NULL, NULL, NULL, false, true),
    ('3.13.11', 1, 'SC', 'derived', 'FIPS',   's', NULL, 5,    NULL, false, false),
    ('3.1.1',   1, 'AC', 'basic',   'Access', 's', NULL, 5,    NULL, false, false);
INSERT INTO organization (id, legal_name) VALUES ('00000000-0000-0000-0000-0000000000a1', 'Org A');
INSERT INTO assessment (id, org_id, library_version) VALUES
    ('10000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 1),
    ('10000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 1),
    ('10000000-0000-0000-0000-00000000000c', '00000000-0000-0000-0000-0000000000a1', 1),
    ('10000000-0000-0000-0000-00000000000e', '00000000-0000-0000-0000-0000000000a1', 1);
INSERT INTO ssp_narrative (assessment_id, requirement_id, draft_text, final_text, edited_by) VALUES
    ('10000000-0000-0000-0000-00000000000a', '3.5.3',   'AI draft', E'MFA — enforced for all users (café ✓)', 'alice'),
    ('10000000-0000-0000-0000-00000000000a', '3.12.4',  'AI draft', E'SSP v1.0\n\tApproved 2026-10-01', 'alice'),
    ('10000000-0000-0000-0000-00000000000a', '3.13.11', 'draft only, never finalized', NULL, 'alice'),
    ('10000000-0000-0000-0000-00000000000a', '3.1.1',   'AI draft', '', 'alice'),
    ('10000000-0000-0000-0000-00000000000c', '3.5.3',   'd', 'MFA text for C', 'carol'),
    ('10000000-0000-0000-0000-00000000000e', '3.5.3',   'd', 'the real section', 'erin');

SELECT t_raises('a snapshot cannot be inserted directly',
    $$INSERT INTO ssp_snapshot (assessment_id, library_version, requirement_id, final_text)
      VALUES ('10000000-0000-0000-0000-00000000000a', 1, '3.5.3', 'invented')$$,
    'ssp_snapshot is written only by signing an assessment');
SELECT t_raises('a digest cannot be inserted directly',
    $$INSERT INTO ssp_snapshot_digest (assessment_id, section_count, sha256)
      VALUES ('10000000-0000-0000-0000-00000000000a', 0, repeat('0', 64))$$,
    'ssp_snapshot_digest is written only by signing an assessment');

SELECT t_raises('a signing that fails its checks (no signer)...',
    $$UPDATE assessment SET status = 'signed' WHERE id = '10000000-0000-0000-0000-00000000000c'$$,
    'assessment_check');
SELECT t_eq('... takes no snapshot',
            (SELECT count(*) FROM ssp_snapshot WHERE assessment_id = '10000000-0000-0000-0000-00000000000c')
          + (SELECT count(*) FROM ssp_snapshot_digest WHERE assessment_id = '10000000-0000-0000-0000-00000000000c'), 0);

UPDATE assessment SET status = 'signed', signed_by = 'CEO', signed_at = now()
WHERE id = '10000000-0000-0000-0000-00000000000a';

SELECT t_eq('signing copies every SSP section',
            (SELECT count(*) FROM ssp_snapshot WHERE assessment_id = '10000000-0000-0000-0000-00000000000a'), 4);
SELECT t_eq('the snapshot matches the narrative exactly at signing',
            (SELECT count(*) FROM (
                SELECT assessment_id, library_version, requirement_id, draft_text, final_text, edited_by
                FROM ssp_narrative WHERE assessment_id = '10000000-0000-0000-0000-00000000000a'
                EXCEPT
                SELECT assessment_id, library_version, requirement_id, draft_text, final_text, edited_by
                FROM ssp_snapshot WHERE assessment_id = '10000000-0000-0000-0000-00000000000a') d), 0);

-- per-section hashes against sha256sum
SELECT t_eq('section hash of non-ASCII text matches sha256sum',
            (SELECT final_sha256 FROM ssp_snapshot WHERE assessment_id = '10000000-0000-0000-0000-00000000000a' AND requirement_id = '3.5.3'),
            'ea9ae7a53d6e8b1f0e6a8fcc38b7076436240619a2038cc87cf77e997c20e84e');
SELECT t_eq('section hash of text with a tab and newline matches sha256sum',
            (SELECT final_sha256 FROM ssp_snapshot WHERE assessment_id = '10000000-0000-0000-0000-00000000000a' AND requirement_id = '3.12.4'),
            '5698ead50ffb9be4489308ee87d3c6ee8af116e8e1b848160bc1c70947046547');
SELECT t_eq('section hash of an empty string is SHA-256 of nothing',
            (SELECT final_sha256 FROM ssp_snapshot WHERE assessment_id = '10000000-0000-0000-0000-00000000000a' AND requirement_id = '3.1.1'),
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
SELECT t_eq('a section with no final text has no hash',
            (SELECT final_sha256 FROM ssp_snapshot WHERE assessment_id = '10000000-0000-0000-0000-00000000000a' AND requirement_id = '3.13.11'),
            NULL::text);

-- whole-SSP digest against sha256sum
SELECT t_eq('digest counts the sections',
            (SELECT section_count FROM ssp_snapshot_digest WHERE assessment_id = '10000000-0000-0000-0000-00000000000a'), 4);
SELECT t_eq('digest matches the documented manifest hashed with sha256sum',
            (SELECT sha256 FROM ssp_snapshot_digest WHERE assessment_id = '10000000-0000-0000-0000-00000000000a'),
            'd7f78f80e6962fbd61ab95dca036ac5207fbf2cbddfa9581eb72dbac3697fcce');

UPDATE assessment SET status = 'signed', signed_by = 'CEO', signed_at = now()
WHERE id = '10000000-0000-0000-0000-00000000000b';
SELECT t_eq('signing with no SSP sections still writes a digest row: 0 sections, hash of nothing',
            (SELECT section_count || '|' || sha256 FROM ssp_snapshot_digest WHERE assessment_id = '10000000-0000-0000-0000-00000000000b'),
            '0|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');

UPDATE assessment SET signed_by = 'CFO', signed_at = now(), status = 'signed', scope_notes = 'final scope'
WHERE id = '10000000-0000-0000-0000-00000000000c';
SELECT t_eq('signing in the same statement as other column changes still snapshots',
            (SELECT final_text FROM ssp_snapshot WHERE assessment_id = '10000000-0000-0000-0000-00000000000c'), 'MFA text for C');

-- the living document vs the snapshot
SELECT t_ok('after signing, SSP sections can still be edited, added and removed',
    $$UPDATE ssp_narrative SET final_text = 'MFA only for admins now.'
          WHERE assessment_id = '10000000-0000-0000-0000-00000000000a' AND requirement_id = '3.5.3';
      DELETE FROM ssp_narrative WHERE assessment_id = '10000000-0000-0000-0000-00000000000a' AND requirement_id = '3.1.1'$$);
SELECT t_eq('the snapshot still holds the signed text',
            (SELECT final_text FROM ssp_snapshot WHERE assessment_id = '10000000-0000-0000-0000-00000000000a' AND requirement_id = '3.5.3'),
            E'MFA — enforced for all users (café ✓)');
SELECT t_eq('the digest is unchanged by later edits',
            (SELECT sha256 FROM ssp_snapshot_digest WHERE assessment_id = '10000000-0000-0000-0000-00000000000a'),
            'd7f78f80e6962fbd61ab95dca036ac5207fbf2cbddfa9581eb72dbac3697fcce');

-- tampering
SELECT t_raises('snapshot rows cannot be updated',
    $$UPDATE ssp_snapshot SET final_text = 'rewritten'$$, 'ssp_snapshot is append-only (UPDATE rejected)');
SELECT t_raises('snapshot rows cannot be deleted',
    $$DELETE FROM ssp_snapshot$$, 'ssp_snapshot is append-only (DELETE rejected)');
SELECT t_raises('snapshots cannot be truncated',
    $$TRUNCATE ssp_snapshot$$, 'ssp_snapshot is append-only (TRUNCATE rejected)');
SELECT t_raises('a section cannot be backfilled into a signed snapshot',
    $$INSERT INTO ssp_snapshot (assessment_id, library_version, requirement_id, final_text)
      VALUES ('10000000-0000-0000-0000-00000000000b', 1, '3.13.11', 'backfilled')$$,
    'ssp_snapshot is written only by signing an assessment');
SELECT t_raises('a digest cannot be rewritten',
    $$UPDATE ssp_snapshot_digest SET sha256 = repeat('0', 64)$$, 'ssp_snapshot_digest is append-only (UPDATE rejected)');
SELECT t_raises('a digest cannot be deleted',
    $$DELETE FROM ssp_snapshot_digest$$, 'ssp_snapshot_digest is append-only (DELETE rejected)');
SELECT t_raises('digests cannot be truncated',
    $$TRUNCATE ssp_snapshot_digest$$, 'ssp_snapshot_digest is append-only (TRUNCATE rejected)');

UPDATE assessment SET status = 'superseded' WHERE id = '10000000-0000-0000-0000-00000000000a';
SELECT t_eq('superseding takes no new snapshot',
            (SELECT count(*) FROM ssp_snapshot WHERE assessment_id = '10000000-0000-0000-0000-00000000000a')
          + (SELECT count(*) FROM ssp_snapshot_digest WHERE assessment_id = '10000000-0000-0000-0000-00000000000a'), 5);

-- A non-owner role with write access (pg_write_all_data stands in for the app role) can't
-- get rows into a snapshot ahead of the signing: not directly, not from a trigger of its own,
-- and not by attaching the signing function to a table it controls. (The table owner can
-- bypass every guard here, like everywhere else in the schema.)
SET ROLE pg_write_all_data;
SELECT t_raises('a non-owner with INSERT privilege cannot insert a snapshot row',
    $$INSERT INTO ssp_snapshot (assessment_id, library_version, requirement_id, final_text)
      VALUES ('10000000-0000-0000-0000-00000000000e', 1, '3.13.11', 'invented')$$,
    'ssp_snapshot is written only by signing an assessment');
SELECT t_raises('... nor plant one from a trigger of its own (trigger depth 2)',
    $$CREATE TEMP TABLE smuggle (x INT);
      CREATE FUNCTION pg_temp.smuggle() RETURNS trigger LANGUAGE plpgsql AS $f$
      BEGIN
          INSERT INTO ssp_snapshot (assessment_id, library_version, requirement_id, final_text, final_sha256)
          VALUES ('10000000-0000-0000-0000-00000000000e', 1, '3.13.11', 'invented', repeat('0', 64));
          RETURN NULL;
      END $f$;
      CREATE TRIGGER smuggle AFTER INSERT ON smuggle FOR EACH ROW EXECUTE FUNCTION pg_temp.smuggle();
      INSERT INTO smuggle VALUES (1)$$,
    'ssp_snapshot is written only by signing an assessment');
SELECT t_raises('... nor plant a digest that way',
    $$CREATE TEMP TABLE smuggle (x INT);
      CREATE FUNCTION pg_temp.smuggle() RETURNS trigger LANGUAGE plpgsql AS $f$
      BEGIN
          INSERT INTO ssp_snapshot_digest (assessment_id, section_count, sha256)
          VALUES ('10000000-0000-0000-0000-00000000000e', 0, repeat('0', 64));
          RETURN NULL;
      END $f$;
      CREATE TRIGGER smuggle AFTER INSERT ON smuggle FOR EACH ROW EXECUTE FUNCTION pg_temp.smuggle();
      INSERT INTO smuggle VALUES (1)$$,
    'ssp_snapshot_digest is written only by signing an assessment');
SELECT t_raises('... nor attach the signing function to a table it controls',
    $$CREATE TEMP TABLE fake_assessment (id UUID, status TEXT);
      CREATE TRIGGER fake AFTER UPDATE ON fake_assessment FOR EACH ROW EXECUTE FUNCTION snapshot_ssp_on_sign()$$,
    'permission denied for function snapshot_ssp_on_sign');
RESET ROLE;

UPDATE assessment SET status = 'signed', signed_by = 'CEO', signed_at = now()
WHERE id = '10000000-0000-0000-0000-00000000000e';
SELECT t_eq('the signed snapshot holds only the real section',
            (SELECT string_agg(requirement_id || '=' || final_text, ',') FROM ssp_snapshot
             WHERE assessment_id = '10000000-0000-0000-0000-00000000000e'), '3.5.3=the real section');
SELECT t_eq('... and the digest counts only that section',
            (SELECT section_count FROM ssp_snapshot_digest WHERE assessment_id = '10000000-0000-0000-0000-00000000000e'), 1);

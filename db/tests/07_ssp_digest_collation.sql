-- createdb-options: --template=template0 --locale-provider=icu --icu-locale=en-US --locale=C.UTF-8
--
-- The SSP digest orders sections by requirement_id in byte order (COLLATE "C") whatever the
-- database's default collation is. This file runs in an ICU en-US database, where 'a.1' sorts
-- before 'B.1'; in byte order 'B.1' comes first. The expected digest was computed outside
-- Postgres from the byte-ordered manifest:
--   printf 'B.1\t%s\na.1\t%s\n' "$(printf bravo | sha256sum | cut -d' ' -f1)" \
--                                "$(printf alpha | sha256sum | cut -d' ' -f1)" | sha256sum
--     -> a8292d5b5b8364cd314d136160efd2f4cead60a2d104f014889b7ac0156f0fb3
-- Ordering by the database default instead would give 8f2315583df81274568a787cca1e56488ae154db934f74e35a4846e389730d50.

SELECT t_eq('fixture: this database sorts a.1 before B.1 (not byte order)',
            (SELECT string_agg(x, ',' ORDER BY x) FROM (VALUES ('B.1'), ('a.1')) v(x)), 'a.1,B.1');

INSERT INTO requirement VALUES
    ('a.1', 1, 'IA', 'basic', 'Synthetic A', 's', NULL, 1, NULL, true, false),
    ('B.1', 1, 'IA', 'basic', 'Synthetic B', 's', NULL, 1, NULL, true, false);
INSERT INTO organization (id, legal_name) VALUES ('00000000-0000-0000-0000-0000000000a1', 'Org A');
INSERT INTO assessment (id, org_id, library_version)
VALUES ('10000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 1);
INSERT INTO ssp_narrative (assessment_id, requirement_id, final_text) VALUES
    ('10000000-0000-0000-0000-00000000000a', 'a.1', 'alpha'),
    ('10000000-0000-0000-0000-00000000000a', 'B.1', 'bravo');
UPDATE assessment SET status = 'signed', signed_by = 'CEO', signed_at = now()
WHERE id = '10000000-0000-0000-0000-00000000000a';

SELECT t_eq('the digest uses byte order regardless of the database collation',
            (SELECT sha256 FROM ssp_snapshot_digest WHERE assessment_id = '10000000-0000-0000-0000-00000000000a'),
            'a8292d5b5b8364cd314d136160efd2f4cead60a2d104f014889b7ac0156f0fb3');

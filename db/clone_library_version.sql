-- Start a new library version as a copy of an existing one, then edit the copy.
-- Load after schema.sql (CREATE OR REPLACE, so it's safe to re-run).
--
-- Copies every row of control_family, requirement, assessment_objective, check_rule and
-- evidence_method from the source version, swapping in the new library_version. Columns are
-- read from the catalog at run time, so a column added to a library table later is copied too
-- instead of silently arriving empty. Serial, identity and generated columns are left to
-- regenerate (evidence_method.id). The source may be frozen; it's only read.
--
-- The source is the newest version (highest id) unless source_version is given. framework and
-- revision default to the source's; notes defaults to 'Copied from library_version N'.
--
-- Clone and edit in one transaction, so a failed edit leaves no half-made version behind and
-- nobody can sign an assessment against the copy before the edits land:
--
--   BEGIN;
--   SELECT clone_library_version(
--       methodology    => 'DoD Assessment Methodology v1.3',
--       effective_date => '2027-01-01') AS new_version \gset
--   UPDATE requirement SET sprs_weight = 3
--    WHERE library_version = :new_version AND id = '3.5.3';
--   UPDATE check_rule SET logic = '{"min_coverage": 1.0}'
--    WHERE library_version = :new_version AND id = 'IA-MFA-ALL-USERS';
--   COMMIT;

CREATE OR REPLACE FUNCTION clone_library_version(
    methodology    TEXT,
    effective_date DATE,
    source_version INT  DEFAULT NULL,
    notes          TEXT DEFAULT NULL,
    framework      TEXT DEFAULT NULL,
    revision       TEXT DEFAULT NULL
) RETURNS INT LANGUAGE plpgsql AS $$
DECLARE
    src     library_version%ROWTYPE;
    new_id  INT;
    tbl     TEXT;
    cols    TEXT;
    n_src   BIGINT;
    n_new   BIGINT;
BEGIN
    SELECT * INTO src FROM library_version
    WHERE id = coalesce(source_version, (SELECT max(id) FROM library_version));
    IF NOT FOUND THEN
        RAISE EXCEPTION 'clone_library_version: library_version % does not exist',
            coalesce(source_version::text, '(none at all)');
    END IF;

    INSERT INTO library_version (framework, revision, methodology, effective_date, notes)
    VALUES (coalesce(clone_library_version.framework, src.framework),
            coalesce(clone_library_version.revision, src.revision),
            clone_library_version.methodology,
            clone_library_version.effective_date,
            coalesce(clone_library_version.notes, format('Copied from library_version %s', src.id)))
    RETURNING id INTO new_id;

    -- Parents before children, so each composite FK finds its target in the new version.
    FOREACH tbl IN ARRAY ARRAY['control_family', 'requirement', 'assessment_objective',
                               'check_rule', 'evidence_method'] LOOP
        SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY a.attnum) INTO cols
        FROM pg_attribute a
        LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
        WHERE a.attrelid = tbl::regclass
          AND a.attnum > 0 AND NOT a.attisdropped
          AND a.attname <> 'library_version'
          AND a.attidentity = '' AND a.attgenerated = ''
          AND coalesce(pg_get_expr(d.adbin, d.adrelid), '') NOT LIKE 'nextval(%';

        EXECUTE format('INSERT INTO %I (library_version, %s) SELECT $1, %s FROM %I WHERE library_version = $2',
                       tbl, cols, cols, tbl)
        USING new_id, src.id;

        -- A BEFORE trigger returning NULL would drop rows without an error; make that loud.
        EXECUTE format('SELECT (SELECT count(*) FROM %1$I WHERE library_version = $1),
                               (SELECT count(*) FROM %1$I WHERE library_version = $2)', tbl)
        INTO n_src, n_new
        USING src.id, new_id;
        IF n_new <> n_src THEN
            RAISE EXCEPTION 'clone_library_version: copied % of % rows of %', n_new, n_src, tbl;
        END IF;
    END LOOP;

    RETURN new_id;
END $$;

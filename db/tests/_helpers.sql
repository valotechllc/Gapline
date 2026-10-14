-- Assertion helpers for db/tests. Loaded by run.sh after the schema, before each test file.
-- Each check prints "ok - <label>" as a NOTICE. A failing check raises "FAIL - <label>: ...",
-- and run.sh (psql ON_ERROR_STOP) stops that file there.
-- Statements passed as text run in a subtransaction: a statement expected to fail leaves no trace.

-- stmt must succeed.
CREATE FUNCTION t_ok(label TEXT, stmt TEXT) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE stmt;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'FAIL - %: expected success, got: %', label, SQLERRM;
    END;
    RAISE NOTICE 'ok - %', label;
END $$;

-- stmt must fail with an error message containing fragment (plain substring, not a regex).
CREATE FUNCTION t_raises(label TEXT, stmt TEXT, fragment TEXT) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE stmt;
    EXCEPTION WHEN OTHERS THEN
        IF strpos(SQLERRM, fragment) > 0 THEN
            RAISE NOTICE 'ok - %', label;
            RETURN;
        END IF;
        RAISE EXCEPTION 'FAIL - %: expected an error containing "%", got: %', label, fragment, SQLERRM;
    END;
    RAISE EXCEPTION 'FAIL - %: expected an error containing "%", but it succeeded', label, fragment;
END $$;

-- actual must equal expected (NULLs compare equal).
CREATE FUNCTION t_eq(label TEXT, actual anycompatible, expected anycompatible) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'FAIL - %: expected %, got %', label, coalesce(expected::text, 'NULL'),
            coalesce(actual::text, 'NULL');
    END IF;
    RAISE NOTICE 'ok - %', label;
END $$;

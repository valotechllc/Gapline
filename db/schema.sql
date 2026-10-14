-- NIST 800-171 Rev 2 Assessment Tool — Control Library & Assessment Schema (PostgreSQL 13+; tested on 16)
-- Design rule: the LIBRARY tables are static reference data you own and version.
-- The ASSESSMENT tables are per-customer. The LLM never writes scores directly.

-- =========================================================
-- 1. CONTROL LIBRARY (your IP — seed once, version carefully)
-- =========================================================

CREATE TABLE library_version (
    id              SERIAL PRIMARY KEY,
    framework       TEXT NOT NULL,           -- 'NIST SP 800-171'
    revision        TEXT NOT NULL,           -- 'Rev 2' (what CMMC/SPRS assess today)
    methodology     TEXT NOT NULL,           -- 'DoD Assessment Methodology v1.2.1'
    effective_date  DATE NOT NULL,
    notes           TEXT
);

CREATE TABLE control_family (
    code            TEXT PRIMARY KEY,        -- 'AC', 'IA', 'SC' ...
    name            TEXT NOT NULL            -- 'Access Control'
);

-- Library rows are keyed by (library_version, id), so a new version can reuse the Rev 2 IDs
-- ('3.5.3') with different weights or text and sit beside the old one. Every table that points
-- at a requirement or objective carries library_version too.
CREATE TABLE requirement (
    id              TEXT NOT NULL,           -- '3.5.3'
    library_version INT  NOT NULL REFERENCES library_version(id),
    family_code     TEXT NOT NULL REFERENCES control_family(code),
    req_type        TEXT NOT NULL CHECK (req_type IN ('basic','derived')),
    title           TEXT NOT NULL,
    statement       TEXT NOT NULL,           -- official requirement text
    plain_english   TEXT,                    -- your rewrite for the interview UI
    sprs_weight     SMALLINT,                -- 1, 3 or 5. May be NULL only where blocks_scoring (3.12.4),
                                             -- whose failure voids the score instead of deducting points
    partial_rule    JSONB,                   -- partial-credit logic, e.g. 3.5.3, 3.13.11 (see seed below)
    poam_eligible   BOOLEAN NOT NULL,        -- can it sit on a POA&M under the CMMC rule? (necessary, not
                                             -- sufficient: see POA&M note in section 3)
    blocks_scoring  BOOLEAN NOT NULL DEFAULT FALSE,  -- 3.12.4: no SSP = no valid score at all
    PRIMARY KEY (library_version, id),
    CHECK ((sprs_weight IS NOT NULL AND sprs_weight IN (1,3,5))
        OR (sprs_weight IS NULL AND blocks_scoring))
);

CREATE TABLE assessment_objective (
    id              TEXT NOT NULL,           -- '3.5.3[a]' (from 800-171A; 320 total)
    library_version INT  NOT NULL,
    requirement_id  TEXT NOT NULL,
    letter          TEXT NOT NULL,           -- 'a','b','c'...
    text            TEXT NOT NULL,
    odp             BOOLEAN NOT NULL DEFAULT FALSE,  -- needs an org-defined parameter?
    PRIMARY KEY (library_version, id),
    FOREIGN KEY (library_version, requirement_id) REFERENCES requirement(library_version, id)
);

-- Deterministic checks. Code decides these, not the model.
CREATE TABLE check_rule (
    id              TEXT PRIMARY KEY,        -- 'IA-MFA-ALL-USERS'
    description     TEXT NOT NULL,
    source          TEXT NOT NULL,           -- 'graph', 'exo_powershell', 'scc_powershell', 'intune'
    logic           JSONB NOT NULL,          -- declarative condition evaluated by your engine
    license_needed  TEXT                     -- 'Entra ID P1' etc. — flag when missing, don't fail silently
);

-- How each objective CAN be evidenced. One objective -> many methods.
CREATE TABLE evidence_method (
    id              SERIAL PRIMARY KEY,
    library_version INT  NOT NULL,
    objective_id    TEXT NOT NULL,
    method_type     TEXT NOT NULL CHECK (method_type IN
                        ('automated_check','interview','document','screenshot','attestation')),
    collector       TEXT,                    -- 'graph.conditional_access', 'exo.mailbox_audit', NULL for manual
    rule_id         TEXT REFERENCES check_rule(id),   -- deterministic rule, if automated
    interview_prompt TEXT,                   -- question asked when no automated source exists
    assessor_guidance TEXT,                  -- what an assessor would want to see
    FOREIGN KEY (library_version, objective_id) REFERENCES assessment_objective(library_version, id)
);

-- =========================================================
-- 2. CUSTOMER / ASSESSMENT DATA
-- =========================================================

CREATE TABLE organization (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legal_name      TEXT NOT NULL,
    cage_code       TEXT,
    m365_cloud      TEXT CHECK (m365_cloud IN ('commercial','gcc','gcc_high')),
    tenant_id       TEXT,
    employee_count  INT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE assessment (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id          UUID NOT NULL REFERENCES organization(id),
    library_version INT  NOT NULL REFERENCES library_version(id),
    scope_notes     TEXT,                    -- CUI boundary description — drives everything
    status          TEXT NOT NULL DEFAULT 'in_progress'
                        CHECK (status IN ('in_progress','in_review','signed','superseded')),
    signed_by       TEXT,                    -- the human who attests (senior official for SPRS)
    signed_at       TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (status <> 'signed' OR (signed_by IS NOT NULL AND signed_at IS NOT NULL)),
    -- Target for the composite FKs below: results, SSP text and POA&M items must use library rows
    -- from this assessment's version. It also blocks changing library_version once any exist.
    UNIQUE (id, library_version)
);

-- Raw evidence, immutable. Hash it so you can prove what you saw and when.
-- Hash the raw bytes as received and keep those bytes at file_uri. Don't hash payload:
-- JSONB reorders keys, strips whitespace and drops duplicate keys, so the stored payload
-- will not reproduce the hash of what the API actually returned.
CREATE TABLE evidence_item (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    assessment_id   UUID NOT NULL REFERENCES assessment(id),
    source          TEXT NOT NULL,           -- 'graph', 'exo_powershell', 'upload', 'interview'
    collector       TEXT,
    payload         JSONB,                   -- parsed copy for querying; not the evidence of record
    file_uri        TEXT,                    -- raw bytes in object storage (API responses and uploads)
    sha256          TEXT NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),  -- of file_uri bytes; of payload::text for interviews
    collected_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (file_uri IS NOT NULL OR (source = 'interview' AND payload IS NOT NULL)),
    UNIQUE (id, assessment_id)               -- lets objective_evidence pin evidence to its own assessment
);

-- Enforce "immutable". This only stops the application role: whoever owns the table can
-- drop the trigger, so the app must not connect as the table owner.
CREATE FUNCTION reject_evidence_change() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'evidence_item is append-only (% rejected)', TG_OP;
END $$;

CREATE TRIGGER evidence_item_no_update_delete BEFORE UPDATE OR DELETE ON evidence_item
    FOR EACH ROW EXECUTE FUNCTION reject_evidence_change();
CREATE TRIGGER evidence_item_no_truncate BEFORE TRUNCATE ON evidence_item
    FOR EACH STATEMENT EXECUTE FUNCTION reject_evidence_change();

-- One row per objective per assessment. Three separate opinions, kept apart on purpose.
CREATE TABLE objective_result (
    assessment_id   UUID NOT NULL,
    library_version INT  NOT NULL,           -- filled from the assessment if omitted; must match it (FK)
    objective_id    TEXT NOT NULL,
    rule_result     TEXT CHECK (rule_result IN ('met','not_met','unknown')),  -- deterministic
    ai_result       TEXT CHECK (ai_result   IN ('met','not_met','insufficient_evidence')),
    ai_rationale    TEXT,
    ai_model        TEXT,                    -- model + version used, for audit trail
    human_result    TEXT CHECK (human_result IN ('met','not_met','not_applicable')),
    reviewer        TEXT,
    reviewed_at     TIMESTAMPTZ,
    PRIMARY KEY (assessment_id, objective_id),
    FOREIGN KEY (assessment_id, library_version) REFERENCES assessment(id, library_version),
    FOREIGN KEY (library_version, objective_id) REFERENCES assessment_objective(library_version, id),
    CHECK (human_result IS NULL OR (reviewer IS NOT NULL AND reviewed_at IS NOT NULL)),
    CHECK (ai_result IS NULL OR ai_model IS NOT NULL)
);

CREATE TABLE objective_evidence (            -- which evidence supports which objective
    assessment_id   UUID NOT NULL,
    objective_id    TEXT NOT NULL,
    evidence_id     UUID NOT NULL,
    PRIMARY KEY (assessment_id, objective_id, evidence_id),
    FOREIGN KEY (assessment_id, objective_id) REFERENCES objective_result(assessment_id, objective_id),
    -- Same assessment_id on both sides, so one customer's evidence can't back another's objective.
    FOREIGN KEY (evidence_id, assessment_id) REFERENCES evidence_item(id, assessment_id)
);

-- Once an assessment is signed, the results it attests to can't change underneath the signature.
-- To revise, start a new assessment and mark the old one 'superseded'.
CREATE FUNCTION reject_change_if_signed() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM assessment
               WHERE status IN ('signed','superseded')
                 AND id IN (CASE WHEN TG_OP <> 'INSERT' THEN OLD.assessment_id END,
                            CASE WHEN TG_OP <> 'DELETE' THEN NEW.assessment_id END)) THEN
        RAISE EXCEPTION '% on % rejected: assessment is signed or superseded', TG_OP, TG_TABLE_NAME;
    END IF;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;

CREATE TRIGGER objective_result_lock BEFORE INSERT OR UPDATE OR DELETE ON objective_result
    FOR EACH ROW EXECUTE FUNCTION reject_change_if_signed();
CREATE TRIGGER objective_evidence_lock BEFORE INSERT OR UPDATE OR DELETE ON objective_evidence
    FOR EACH ROW EXECUTE FUNCTION reject_change_if_signed();

-- SSP narrative per requirement (AI drafts, human edits).
CREATE TABLE ssp_narrative (
    assessment_id   UUID NOT NULL,
    library_version INT  NOT NULL,           -- filled from the assessment if omitted; must match it (FK)
    requirement_id  TEXT NOT NULL,
    draft_text      TEXT,
    final_text      TEXT,
    edited_by       TEXT,
    PRIMARY KEY (assessment_id, requirement_id),
    FOREIGN KEY (assessment_id, library_version) REFERENCES assessment(id, library_version),
    FOREIGN KEY (library_version, requirement_id) REFERENCES requirement(library_version, id)
);

CREATE TABLE poam_item (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    assessment_id   UUID NOT NULL,
    library_version INT  NOT NULL,           -- filled from the assessment if omitted; must match it (FK)
    requirement_id  TEXT NOT NULL,
    weakness        TEXT NOT NULL,
    remediation     TEXT NOT NULL,
    est_cost_usd    NUMERIC(10,2),
    points_recovered SMALLINT,               -- drives the "fix this first" ranking
    owner           TEXT,
    due_date        DATE,
    status          TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','in_progress','closed')),
    FOREIGN KEY (assessment_id, library_version) REFERENCES assessment(id, library_version),
    FOREIGN KEY (library_version, requirement_id) REFERENCES requirement(library_version, id)
);

-- Callers may omit library_version: copy it from the assessment. An explicit value is kept
-- as given, so a wrong one still fails the FK instead of being silently corrected.
-- (BEFORE triggers run ahead of the NOT NULL check, so the column can stay NOT NULL.)
CREATE FUNCTION fill_library_version() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.library_version IS NULL THEN
        SELECT library_version INTO NEW.library_version FROM assessment WHERE id = NEW.assessment_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'insert on %: assessment % does not exist', TG_TABLE_NAME, NEW.assessment_id
                USING ERRCODE = 'foreign_key_violation';
        END IF;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER objective_result_fill_version BEFORE INSERT ON objective_result
    FOR EACH ROW EXECUTE FUNCTION fill_library_version();
CREATE TRIGGER ssp_narrative_fill_version BEFORE INSERT ON ssp_narrative
    FOR EACH ROW EXECUTE FUNCTION fill_library_version();
CREATE TRIGGER poam_item_fill_version BEFORE INSERT ON poam_item
    FOR EACH ROW EXECUTE FUNCTION fill_library_version();

-- =========================================================
-- 3. SCORING — derived only from HUMAN results
-- =========================================================
-- A requirement is MET only if every one of its objectives is met (or N/A).
-- Driven from the library, not from objective_result: an objective with no result row,
-- or a requirement with no rows at all, must come out 'unreviewed' rather than vanish
-- (a vanished requirement means a missed deduction and an inflated score).
CREATE VIEW requirement_status AS
SELECT
    a.id AS assessment_id,
    a.library_version,
    r.id AS requirement_id,
    r.sprs_weight,
    r.partial_rule,
    r.blocks_scoring,
    count(ao.id)          AS objectives_total,
    count(o.human_result) AS objectives_reviewed,
    CASE
        -- No objectives loaded for this requirement is a library seeding error; fail closed.
        WHEN count(ao.id) = 0 THEN 'unreviewed'
        WHEN count(o.human_result) < count(ao.id) THEN 'unreviewed'
        WHEN bool_and(o.human_result IN ('met','not_applicable')) THEN 'met'
        ELSE 'not_met'
    END AS status
FROM assessment a
JOIN requirement r                ON r.library_version = a.library_version
LEFT JOIN assessment_objective ao ON ao.library_version = r.library_version AND ao.requirement_id = r.id
LEFT JOIN objective_result o      ON o.assessment_id = a.id
                                 AND o.library_version = ao.library_version AND o.objective_id = ao.id
GROUP BY a.id, r.library_version, r.id;

-- Final SPRS math (110 minus deductions, floor -203) lives in application code,
-- where partial_rule can be evaluated and unit-tested against known examples.
-- Refuse to output a score if any requirement is 'unreviewed' or 3.12.4 is not met.
--
-- POA&M eligibility is not a per-requirement fact, so poam_eligible alone can't decide it.
-- As commonly summarized from 32 CFR 170.21 (verify against the eCFR text before relying on it):
--   * the assessment score must be at least 80% of the maximum (88/110);
--   * only 1-point requirements, plus 3.13.11 when the deduction is the partial (-3,
--     encryption used but not FIPS-validated) one;
--   * never 3.1.20, 3.1.22, 3.12.4, 3.10.3, 3.10.4, 3.10.5, even though most are 1-pointers;
--   * close-out within 180 days.

-- =========================================================
-- 4. EXAMPLE SEED ROWS
-- =========================================================
INSERT INTO control_family VALUES ('IA','Identification and Authentication'),
                                  ('SC','System and Communications Protection');

-- 3.5.3: -5 if no MFA; -3 if MFA for remote + privileged but not all network access
-- 3.13.11: -5 if no encryption on CUI; -3 if encryption used but not FIPS-validated
-- Verify every weight and partial rule against the current DoD Assessment Methodology before launch.

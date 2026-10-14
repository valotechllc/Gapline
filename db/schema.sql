-- NIST 800-171 Rev 2 Assessment Tool — Control Library & Assessment Schema (PostgreSQL)
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

CREATE TABLE requirement (
    id              TEXT PRIMARY KEY,        -- '3.5.3'
    library_version INT  NOT NULL REFERENCES library_version(id),
    family_code     TEXT NOT NULL REFERENCES control_family(code),
    req_type        TEXT NOT NULL CHECK (req_type IN ('basic','derived')),
    title           TEXT NOT NULL,
    statement       TEXT NOT NULL,           -- official requirement text
    plain_english   TEXT,                    -- your rewrite for the interview UI
    sprs_weight     SMALLINT NOT NULL CHECK (sprs_weight IN (1,3,5)),
    partial_rule    JSONB,                   -- partial-credit logic, e.g. 3.5.3, 3.13.11 (see seed below)
    poam_eligible   BOOLEAN NOT NULL,        -- can it sit on a POA&M under the CMMC rule?
    blocks_scoring  BOOLEAN NOT NULL DEFAULT FALSE  -- 3.12.4: no SSP = no valid score at all
);

CREATE TABLE assessment_objective (
    id              TEXT PRIMARY KEY,        -- '3.5.3[a]' (from 800-171A; 320 total)
    requirement_id  TEXT NOT NULL REFERENCES requirement(id),
    letter          TEXT NOT NULL,           -- 'a','b','c'...
    text            TEXT NOT NULL,
    odp             BOOLEAN NOT NULL DEFAULT FALSE  -- needs an org-defined parameter?
);

-- Deterministic checks. Code decides these, not the model.
CREATE TABLE check_rule (
    id              TEXT PRIMARY KEY,        -- 'IA-MFA-ALL-USERS'
    description     TEXT NOT NULL,
    source          TEXT NOT NULL,           -- 'graph', 'exo_powershell', 'intune'
    logic           JSONB NOT NULL,          -- declarative condition evaluated by your engine
    license_needed  TEXT                     -- 'Entra ID P1' etc. — flag when missing, don't fail silently
);

-- How each objective CAN be evidenced. One objective -> many methods.
CREATE TABLE evidence_method (
    id              SERIAL PRIMARY KEY,
    objective_id    TEXT NOT NULL REFERENCES assessment_objective(id),
    method_type     TEXT NOT NULL CHECK (method_type IN
                        ('automated_check','interview','document','screenshot','attestation')),
    collector       TEXT,                    -- 'graph.conditional_access', 'exo.mailbox_audit', NULL for manual
    rule_id         TEXT REFERENCES check_rule(id),   -- deterministic rule, if automated
    interview_prompt TEXT,                   -- question asked when no automated source exists
    assessor_guidance TEXT                   -- what an assessor would want to see
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
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Raw evidence, immutable. Hash it so you can prove what you saw and when.
CREATE TABLE evidence_item (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    assessment_id   UUID NOT NULL REFERENCES assessment(id),
    source          TEXT NOT NULL,           -- 'graph', 'upload', 'interview'
    collector       TEXT,
    payload         JSONB,                   -- raw API response or interview answer
    file_uri        TEXT,                    -- for uploads (object storage, not the DB)
    sha256          TEXT NOT NULL,
    collected_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- One row per objective per assessment. Three separate opinions, kept apart on purpose.
CREATE TABLE objective_result (
    assessment_id   UUID NOT NULL REFERENCES assessment(id),
    objective_id    TEXT NOT NULL REFERENCES assessment_objective(id),
    rule_result     TEXT CHECK (rule_result IN ('met','not_met','unknown')),  -- deterministic
    ai_result       TEXT CHECK (ai_result   IN ('met','not_met','insufficient_evidence')),
    ai_rationale    TEXT,
    ai_model        TEXT,                    -- model + version used, for audit trail
    human_result    TEXT CHECK (human_result IN ('met','not_met','not_applicable')),
    reviewer        TEXT,
    reviewed_at     TIMESTAMPTZ,
    PRIMARY KEY (assessment_id, objective_id)
);

CREATE TABLE objective_evidence (            -- which evidence supports which objective
    assessment_id   UUID NOT NULL,
    objective_id    TEXT NOT NULL,
    evidence_id     UUID NOT NULL REFERENCES evidence_item(id),
    PRIMARY KEY (assessment_id, objective_id, evidence_id),
    FOREIGN KEY (assessment_id, objective_id) REFERENCES objective_result(assessment_id, objective_id)
);

-- SSP narrative per requirement (AI drafts, human edits).
CREATE TABLE ssp_narrative (
    assessment_id   UUID NOT NULL REFERENCES assessment(id),
    requirement_id  TEXT NOT NULL REFERENCES requirement(id),
    draft_text      TEXT,
    final_text      TEXT,
    edited_by       TEXT,
    PRIMARY KEY (assessment_id, requirement_id)
);

CREATE TABLE poam_item (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    assessment_id   UUID NOT NULL REFERENCES assessment(id),
    requirement_id  TEXT NOT NULL REFERENCES requirement(id),
    weakness        TEXT NOT NULL,
    remediation     TEXT NOT NULL,
    est_cost_usd    NUMERIC(10,2),
    points_recovered SMALLINT,               -- drives the "fix this first" ranking
    owner           TEXT,
    due_date        DATE,
    status          TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','in_progress','closed'))
);

-- =========================================================
-- 3. SCORING — derived only from HUMAN results
-- =========================================================
-- A requirement is MET only if every one of its objectives is met (or N/A).
CREATE VIEW requirement_status AS
SELECT
    o.assessment_id,
    r.id AS requirement_id,
    r.sprs_weight,
    r.partial_rule,
    CASE
        WHEN bool_and(o.human_result IS NOT NULL) IS NOT TRUE THEN 'unreviewed'
        WHEN bool_and(o.human_result IN ('met','not_applicable')) THEN 'met'
        ELSE 'not_met'
    END AS status
FROM objective_result o
JOIN assessment_objective ao ON ao.id = o.objective_id
JOIN requirement r ON r.id = ao.requirement_id
GROUP BY o.assessment_id, r.id, r.sprs_weight, r.partial_rule;

-- Final SPRS math (110 minus deductions, floor -203) lives in application code,
-- where partial_rule can be evaluated and unit-tested against known examples.
-- Refuse to output a score if any requirement is 'unreviewed' or 3.12.4 is not met.

-- =========================================================
-- 4. EXAMPLE SEED ROWS
-- =========================================================
INSERT INTO control_family VALUES ('IA','Identification and Authentication'),
                                  ('SC','System and Communications Protection');

-- 3.5.3: -5 if no MFA; -3 if MFA for remote + privileged but not all network access
-- 3.13.11: -5 if no encryption on CUI; -3 if encryption used but not FIPS-validated
-- Verify every weight and partial rule against the current DoD Assessment Methodology before launch.

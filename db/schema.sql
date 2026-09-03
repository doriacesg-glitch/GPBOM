-- =============================================================================
-- GPBOM — Green Product BOM & Compliance Management System
-- PostgreSQL 15+ schema (DDL)
--
-- Design principles
--   1. Part vs. PartRevision — BOM binds to Revision, never to bare Part,
--      so historical ("as-built") BOMs can always be reproduced.
--   2. BOM lines carry effectivity dates (tstzrange) driven by PCN.
--   3. Substance / Regulation / Document are first-class master tables
--      (many-to-many), so full-substance search is a JOIN, not a scan.
--   4. Homogeneous-material layer is modelled explicitly — RoHS/REACH
--      thresholds apply at that layer, not at part level.
--   5. Every mutating table carries created_at / updated_at / created_by
--      / updated_by, and mutations are mirrored into audit_log (append-only).
--   6. All monetary/quantity math uses NUMERIC; never FLOAT.
--
-- Conventions
--   * snake_case for identifiers.
--   * Surrogate PK = BIGSERIAL; natural keys carry UNIQUE constraints.
--   * Soft delete via status enums, not DELETE, on master data.
--   * Timestamps stored as TIMESTAMPTZ, UTC.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- Extensions
-- -----------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid, digest()
CREATE EXTENSION IF NOT EXISTS citext;     -- case-insensitive text (emails, CAS)
CREATE EXTENSION IF NOT EXISTS pg_trgm;    -- fuzzy search on part numbers
CREATE EXTENSION IF NOT EXISTS btree_gist; -- exclusion constraints on ranges

CREATE SCHEMA IF NOT EXISTS gpbom;
SET search_path = gpbom, public;

-- -----------------------------------------------------------------------------
-- ENUM types
-- -----------------------------------------------------------------------------
CREATE TYPE part_status       AS ENUM ('active', 'obsolete', 'pending');
CREATE TYPE part_kind         AS ENUM ('assembly', 'sub_assembly', 'component',
                                       'raw_material', 'packaging');
CREATE TYPE document_kind     AS ENUM ('test_report', 'sds', 'declaration',
                                       'survey', 'coc', 'cmrt', 'emrt',
                                       'drawing', 'spec', 'other');
CREATE TYPE pcn_status        AS ENUM ('draft', 'open', 'implemented',
                                       'cancelled');
CREATE TYPE pcn_reason        AS ENUM ('material_change', 'supplier_change',
                                       'manufacturer_change', 'process_change',
                                       'site_change', 'eol', 'design_change',
                                       'regulatory', 'other');
CREATE TYPE user_role         AS ENUM ('admin', 'editor', 'viewer');
CREATE TYPE claim_status      AS ENUM ('active', 'released', 'expired');

-- =============================================================================
-- 1. Identity & audit
-- =============================================================================
CREATE TABLE app_user (
    id            BIGSERIAL PRIMARY KEY,
    username      CITEXT NOT NULL UNIQUE,
    display_name  TEXT   NOT NULL,
    email         CITEXT UNIQUE,
    role          user_role NOT NULL DEFAULT 'viewer',
    is_active     BOOLEAN NOT NULL DEFAULT TRUE,
    password_hash TEXT,                 -- argon2id; NULL = SSO only
    totp_secret   BYTEA,                -- encrypted at rest (pgcrypto)
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- append-only audit log; no UPDATE / DELETE permitted at role level
CREATE TABLE audit_log (
    id          BIGSERIAL PRIMARY KEY,
    at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    actor_id    BIGINT REFERENCES app_user(id),
    table_name  TEXT NOT NULL,
    row_pk      TEXT NOT NULL,
    action      TEXT NOT NULL CHECK (action IN ('INSERT','UPDATE','DELETE')),
    diff        JSONB NOT NULL         -- {before, after}
);
CREATE INDEX audit_log_table_row_idx ON audit_log(table_name, row_pk);
CREATE INDEX audit_log_at_idx        ON audit_log(at DESC);

-- =============================================================================
-- 2. Supplier / Manufacturer master
-- =============================================================================
CREATE TABLE supplier (
    id           BIGSERIAL PRIMARY KEY,
    code         CITEXT NOT NULL UNIQUE,      -- internal supplier code
    name         TEXT   NOT NULL,
    country      CHAR(2),                     -- ISO-3166 alpha-2
    is_active    BOOLEAN NOT NULL DEFAULT TRUE,
    notes        TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   BIGINT REFERENCES app_user(id),
    updated_by   BIGINT REFERENCES app_user(id)
);

CREATE TABLE supplier_contact (
    id            BIGSERIAL PRIMARY KEY,
    supplier_id   BIGINT NOT NULL REFERENCES supplier(id) ON DELETE CASCADE,
    name          TEXT NOT NULL,
    title         TEXT,
    email         CITEXT,
    phone         TEXT,
    is_primary    BOOLEAN NOT NULL DEFAULT FALSE,
    notes         TEXT
);
CREATE INDEX supplier_contact_supplier_idx ON supplier_contact(supplier_id);

CREATE TABLE manufacturer (
    id         BIGSERIAL PRIMARY KEY,
    code       CITEXT NOT NULL UNIQUE,
    name       TEXT   NOT NULL,
    country    CHAR(2),
    notes      TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- =============================================================================
-- 3. Regulation & Substance masters
-- =============================================================================
CREATE TABLE regulation (
    id           BIGSERIAL PRIMARY KEY,
    code         CITEXT NOT NULL,             -- 'RoHS', 'REACH_SVHC', 'Prop65'
    version      TEXT   NOT NULL,             -- 'Annex II 2023/171', 'SVHC-30'
    jurisdiction TEXT,                        -- 'EU', 'US-CA', 'CN', 'Global'
    effective_from DATE NOT NULL,
    effective_to   DATE,                      -- NULL = still in force
    url          TEXT,
    notes        TEXT,
    UNIQUE (code, version)
);

CREATE TABLE substance (
    id            BIGSERIAL PRIMARY KEY,
    cas_no        CITEXT UNIQUE,              -- may be NULL for polymers
    ec_no         CITEXT,
    name_en       TEXT NOT NULL,
    name_zh       TEXT,
    synonyms      TEXT[],
    is_conflict_mineral BOOLEAN NOT NULL DEFAULT FALSE, -- Au/Ta/Sn/W/Co
    notes         TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX substance_name_trgm_idx ON substance USING gin (name_en gin_trgm_ops);
CREATE INDEX substance_syn_idx       ON substance USING gin (synonyms);

-- Substance <-> Regulation, with threshold and effectivity
CREATE TABLE substance_regulation (
    id              BIGSERIAL PRIMARY KEY,
    substance_id    BIGINT NOT NULL REFERENCES substance(id),
    regulation_id   BIGINT NOT NULL REFERENCES regulation(id),
    threshold_ppm   NUMERIC(12,4),            -- NULL = reporting only
    scope           TEXT,                     -- 'homogeneous_material', 'article'
    condition_note  TEXT,                     -- exemptions, use-case caveats
    effective_from  DATE NOT NULL,
    effective_to    DATE,
    UNIQUE (substance_id, regulation_id, effective_from)
);
CREATE INDEX subst_reg_substance_idx  ON substance_regulation(substance_id);
CREATE INDEX subst_reg_regulation_idx ON substance_regulation(regulation_id);

-- =============================================================================
-- 4. Document master (test reports, SDS, declarations …)
-- =============================================================================
CREATE TABLE lab (
    id      BIGSERIAL PRIMARY KEY,
    code    CITEXT NOT NULL UNIQUE,           -- 'SGS','BV','Intertek','TUV'
    name    TEXT   NOT NULL,
    country CHAR(2)
);

CREATE TABLE document (
    id             BIGSERIAL PRIMARY KEY,
    doc_kind       document_kind NOT NULL,
    doc_no         TEXT,                      -- lab report no. / SDS revision
    title          TEXT,
    issued_by_lab  BIGINT REFERENCES lab(id),
    issued_by_supplier BIGINT REFERENCES supplier(id),
    issue_date     DATE NOT NULL,
    expire_date    DATE,                      -- computed on insert if NULL
    language       CHAR(2),
    file_uri       TEXT,                      -- object-storage path
    file_sha256    BYTEA,                     -- integrity check
    file_bytes     BIGINT,
    notes          TEXT,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by     BIGINT REFERENCES app_user(id),
    updated_by     BIGINT REFERENCES app_user(id),
    CHECK (file_sha256 IS NULL OR octet_length(file_sha256) = 32)
);
CREATE INDEX document_expire_idx    ON document(expire_date);
CREATE INDEX document_kind_date_idx ON document(doc_kind, issue_date DESC);

-- Which documents describe a test result — one report → many test items
CREATE TABLE document_test_item (
    id           BIGSERIAL PRIMARY KEY,
    document_id  BIGINT NOT NULL REFERENCES document(id) ON DELETE CASCADE,
    substance_id BIGINT REFERENCES substance(id),
    test_method  TEXT,                          -- 'IEC 62321-5', 'EN 14372'
    result_ppm   NUMERIC(14,4),
    result_text  TEXT,                          -- 'ND', '< LOQ'
    limit_ppm    NUMERIC(14,4),
    pass         BOOLEAN
);
CREATE INDEX doc_test_document_idx  ON document_test_item(document_id);
CREATE INDEX doc_test_substance_idx ON document_test_item(substance_id);

-- Global rule for how long each document kind is valid
CREATE TABLE document_validity_rule (
    doc_kind         document_kind PRIMARY KEY,
    validity_months  INT NOT NULL CHECK (validity_months > 0),
    warn_days_before INT NOT NULL DEFAULT 30,
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by       BIGINT REFERENCES app_user(id)
);

-- =============================================================================
-- 5. Part / PartRevision / Component
-- =============================================================================
CREATE TABLE part (
    id               BIGSERIAL PRIMARY KEY,
    part_no          CITEXT NOT NULL UNIQUE,   -- internal PN
    name             TEXT   NOT NULL,
    kind             part_kind NOT NULL DEFAULT 'component',
    uom              TEXT   NOT NULL DEFAULT 'pcs',
    status           part_status NOT NULL DEFAULT 'active',
    manufacturer_id  BIGINT REFERENCES manufacturer(id),
    mpn              TEXT,                     -- manufacturer P/N
    supplier_id      BIGINT REFERENCES supplier(id),
    supplier_pn      TEXT,
    default_weight_g NUMERIC(14,4),            -- part total weight, grams
    last_purchase_at DATE,
    stock_qty        NUMERIC(14,3) NOT NULL DEFAULT 0,
    notes            TEXT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by       BIGINT REFERENCES app_user(id),
    updated_by       BIGINT REFERENCES app_user(id)
);
CREATE INDEX part_no_trgm_idx    ON part USING gin (part_no gin_trgm_ops);
CREATE INDEX part_name_trgm_idx  ON part USING gin (name    gin_trgm_ops);
CREATE INDEX part_supplier_idx   ON part(supplier_id);
CREATE INDEX part_manuf_idx      ON part(manufacturer_id);
CREATE INDEX part_status_idx     ON part(status);

-- A PartRevision is what BOM lines actually point to.
CREATE TABLE part_revision (
    id              BIGSERIAL PRIMARY KEY,
    part_id         BIGINT NOT NULL REFERENCES part(id) ON DELETE CASCADE,
    rev_code        TEXT   NOT NULL,           -- 'A','B','01'
    effective_from  DATE   NOT NULL,
    effective_to    DATE,
    superseded_by   BIGINT REFERENCES part_revision(id),
    pcn_id          BIGINT,                    -- FK added later (cycle)
    notes           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (part_id, rev_code)
);
CREATE INDEX part_rev_part_idx ON part_revision(part_id);

-- Homogeneous-material layer: RoHS/REACH thresholds apply here.
CREATE TABLE part_material (
    id                BIGSERIAL PRIMARY KEY,
    part_revision_id  BIGINT NOT NULL REFERENCES part_revision(id) ON DELETE CASCADE,
    material_name     TEXT   NOT NULL,          -- 'ABS plastic', 'Solder', 'Copper'
    weight_g          NUMERIC(14,4) NOT NULL,
    location_note     TEXT                      -- 'housing', 'lead frame'
);
CREATE INDEX part_material_rev_idx ON part_material(part_revision_id);

-- Substance content inside a homogeneous material.
CREATE TABLE material_substance (
    id                BIGSERIAL PRIMARY KEY,
    part_material_id  BIGINT NOT NULL REFERENCES part_material(id) ON DELETE CASCADE,
    substance_id      BIGINT NOT NULL REFERENCES substance(id),
    weight_g          NUMERIC(14,6),
    ppm               NUMERIC(14,4),
    source_doc_id     BIGINT REFERENCES document(id),
    UNIQUE (part_material_id, substance_id)
);
CREATE INDEX matsubs_substance_idx ON material_substance(substance_id);

-- =============================================================================
-- 6. BOM — time-effective, quantity + weight-per-parent captured on the line
-- =============================================================================
CREATE TABLE bom_line (
    id                 BIGSERIAL PRIMARY KEY,
    parent_revision_id BIGINT NOT NULL REFERENCES part_revision(id) ON DELETE CASCADE,
    child_revision_id  BIGINT NOT NULL REFERENCES part_revision(id),
    position_no        TEXT,                         -- reference designator
    quantity           NUMERIC(14,4) NOT NULL DEFAULT 1,
    uom                TEXT NOT NULL DEFAULT 'pcs',
    weight_g_per_parent NUMERIC(14,4),               -- as-built weight
    effective_range    TSTZRANGE NOT NULL,
    pcn_id             BIGINT,                       -- FK added later
    notes              TEXT,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by         BIGINT REFERENCES app_user(id),
    CHECK (parent_revision_id <> child_revision_id),
    -- Same child cannot occupy the same position on the same parent
    -- during overlapping effective ranges:
    EXCLUDE USING gist (
        parent_revision_id WITH =,
        child_revision_id  WITH =,
        COALESCE(position_no,'') WITH =,
        effective_range    WITH &&
    )
);
CREATE INDEX bom_parent_idx ON bom_line(parent_revision_id);
CREATE INDEX bom_child_idx  ON bom_line(child_revision_id);

-- Convenience view: currently-effective BOM lines
CREATE VIEW bom_line_current AS
    SELECT * FROM bom_line WHERE effective_range @> now();

-- =============================================================================
-- 7. Document ↔ Part / Supplier / Substance linkage
-- =============================================================================
CREATE TABLE part_document (
    part_revision_id BIGINT NOT NULL REFERENCES part_revision(id) ON DELETE CASCADE,
    document_id      BIGINT NOT NULL REFERENCES document(id) ON DELETE CASCADE,
    PRIMARY KEY (part_revision_id, document_id)
);
CREATE INDEX part_doc_doc_idx ON part_document(document_id);

CREATE TABLE supplier_document (
    supplier_id  BIGINT NOT NULL REFERENCES supplier(id) ON DELETE CASCADE,
    document_id  BIGINT NOT NULL REFERENCES document(id) ON DELETE CASCADE,
    PRIMARY KEY (supplier_id, document_id)
);

-- =============================================================================
-- 8. PCN — Product / Process Change Notice
-- =============================================================================
CREATE TABLE pcn (
    id               BIGSERIAL PRIMARY KEY,
    pcn_no           TEXT NOT NULL UNIQUE,           -- 'PCN00000123'
    supplier_pcn_no  TEXT,
    supplier_id      BIGINT REFERENCES supplier(id),
    manufacturer_id  BIGINT REFERENCES manufacturer(id),
    reason           pcn_reason NOT NULL,
    status           pcn_status NOT NULL DEFAULT 'draft',
    notified_at      DATE,
    implement_at     DATE,
    description      TEXT NOT NULL,
    -- for material / supplier / manufacturer change
    before_mpn       TEXT,
    after_mpn        TEXT,
    before_manuf_id  BIGINT REFERENCES manufacturer(id),
    after_manuf_id   BIGINT REFERENCES manufacturer(id),
    before_supplier_id BIGINT REFERENCES supplier(id),
    after_supplier_id  BIGINT REFERENCES supplier(id),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by       BIGINT REFERENCES app_user(id),
    updated_by       BIGINT REFERENCES app_user(id)
);

CREATE INDEX pcn_supplier_idx ON pcn(supplier_id);
CREATE INDEX pcn_status_idx   ON pcn(status);
CREATE INDEX pcn_implement_idx ON pcn(implement_at);

-- Which parts/revisions/BOM lines a PCN actually touches
CREATE TABLE pcn_impact (
    id               BIGSERIAL PRIMARY KEY,
    pcn_id           BIGINT NOT NULL REFERENCES pcn(id) ON DELETE CASCADE,
    part_id          BIGINT REFERENCES part(id),
    part_revision_id BIGINT REFERENCES part_revision(id),
    bom_line_id      BIGINT REFERENCES bom_line(id),
    impact_note      TEXT,
    CHECK (
        part_id IS NOT NULL
        OR part_revision_id IS NOT NULL
        OR bom_line_id IS NOT NULL
    )
);
CREATE INDEX pcn_impact_pcn_idx  ON pcn_impact(pcn_id);
CREATE INDEX pcn_impact_part_idx ON pcn_impact(part_id);

-- Deferred FKs (cycle: part_revision.pcn_id, bom_line.pcn_id → pcn)
ALTER TABLE part_revision
    ADD CONSTRAINT part_revision_pcn_fk
    FOREIGN KEY (pcn_id) REFERENCES pcn(id);

ALTER TABLE bom_line
    ADD CONSTRAINT bom_line_pcn_fk
    FOREIGN KEY (pcn_id) REFERENCES pcn(id);

-- =============================================================================
-- 9. Ownership / claim ("who is handling this")
-- =============================================================================
CREATE TABLE part_claim (
    id            BIGSERIAL PRIMARY KEY,
    part_id       BIGINT NOT NULL REFERENCES part(id) ON DELETE CASCADE,
    claimed_by    BIGINT NOT NULL REFERENCES app_user(id),
    claimed_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    released_at   TIMESTAMPTZ,
    reason        TEXT,
    status        claim_status NOT NULL DEFAULT 'active'
);
CREATE UNIQUE INDEX part_claim_one_active
    ON part_claim(part_id) WHERE status = 'active';
CREATE INDEX part_claim_user_idx ON part_claim(claimed_by);

-- =============================================================================
-- 10. Helper views
-- =============================================================================

-- 10a. Latest document per (part_revision, doc_kind)
CREATE VIEW part_document_latest AS
SELECT DISTINCT ON (pd.part_revision_id, d.doc_kind)
    pd.part_revision_id,
    d.doc_kind,
    d.id           AS document_id,
    d.doc_no,
    d.issue_date,
    d.expire_date
FROM part_document pd
JOIN document d ON d.id = pd.document_id
ORDER BY pd.part_revision_id, d.doc_kind, d.issue_date DESC;

-- 10b. Documents currently expired or expiring soon (30 days)
CREATE VIEW document_expiring AS
SELECT
    d.*,
    CASE
        WHEN d.expire_date IS NULL             THEN 'no_expiry'
        WHEN d.expire_date <  current_date     THEN 'expired'
        WHEN d.expire_date <= current_date + 30 THEN 'due_soon'
        ELSE 'ok'
    END AS state
FROM document d
WHERE d.expire_date IS NOT NULL
  AND d.expire_date <= current_date + 30;

-- 10c. Recursive BOM explosion for currently-effective lines
CREATE VIEW bom_explosion AS
WITH RECURSIVE walk AS (
    SELECT
        b.parent_revision_id AS root_revision_id,
        b.parent_revision_id,
        b.child_revision_id,
        b.quantity,
        b.weight_g_per_parent,
        1                    AS depth,
        ARRAY[b.parent_revision_id, b.child_revision_id] AS path
    FROM bom_line_current b
    UNION ALL
    SELECT
        w.root_revision_id,
        b.parent_revision_id,
        b.child_revision_id,
        w.quantity * b.quantity,
        b.weight_g_per_parent,
        w.depth + 1,
        w.path || b.child_revision_id
    FROM walk w
    JOIN bom_line_current b ON b.parent_revision_id = w.child_revision_id
    WHERE NOT b.child_revision_id = ANY (w.path)   -- cycle guard
      AND w.depth < 32
)
SELECT * FROM walk;

-- =============================================================================
-- 11. Trigger utilities — updated_at + audit
-- =============================================================================
CREATE OR REPLACE FUNCTION touch_updated_at() RETURNS trigger AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END $$ LANGUAGE plpgsql;

DO $$
DECLARE t TEXT;
BEGIN
    FOR t IN
        SELECT table_name
        FROM information_schema.columns
        WHERE table_schema = 'gpbom'
          AND column_name  = 'updated_at'
    LOOP
        EXECUTE format(
            'CREATE TRIGGER %I_touch BEFORE UPDATE ON gpbom.%I
             FOR EACH ROW EXECUTE FUNCTION gpbom.touch_updated_at();',
            t, t);
    END LOOP;
END $$;

-- Generic audit trigger — writes {before, after} into audit_log.
-- app_user id is read from GUC gpbom.actor_id (set by application per session).
CREATE OR REPLACE FUNCTION write_audit() RETURNS trigger AS $$
DECLARE
    actor BIGINT := NULLIF(current_setting('gpbom.actor_id', true), '')::BIGINT;
    pk    TEXT;
BEGIN
    pk := COALESCE(
        (row_to_json(NEW)->>'id'),
        (row_to_json(OLD)->>'id')
    );
    INSERT INTO audit_log(actor_id, table_name, row_pk, action, diff)
    VALUES (
        actor,
        TG_TABLE_NAME,
        pk,
        TG_OP,
        jsonb_build_object(
            'before', CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END,
            'after',  CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END
        )
    );
    RETURN COALESCE(NEW, OLD);
END $$ LANGUAGE plpgsql;

-- Attach audit to the mutable core tables (extend as needed)
DO $$
DECLARE t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'part','part_revision','part_material','material_substance',
        'bom_line','pcn','pcn_impact','document','part_document',
        'supplier','supplier_contact','manufacturer',
        'substance','substance_regulation','regulation',
        'part_claim'
    ]
    LOOP
        EXECUTE format(
            'CREATE TRIGGER %I_audit AFTER INSERT OR UPDATE OR DELETE ON gpbom.%I
             FOR EACH ROW EXECUTE FUNCTION gpbom.write_audit();',
            t, t);
    END LOOP;
END $$;

-- =============================================================================
-- 12. Seed: document validity rules (defaults — override via UI)
-- =============================================================================
INSERT INTO document_validity_rule (doc_kind, validity_months, warn_days_before)
VALUES
    ('test_report', 12, 30),
    ('sds',         36, 60),
    ('declaration', 12, 30),
    ('survey',      12, 30),
    ('cmrt',        12, 30),
    ('emrt',        12, 30),
    ('coc',         12, 30)
ON CONFLICT (doc_kind) DO NOTHING;

COMMIT;

-- =============================================================================
-- Row-Level Security (optional but recommended)
--   Enable per-role read/write once app roles are provisioned.
--   Left commented so bootstrap is not blocked.
-- =============================================================================
-- ALTER TABLE part          ENABLE ROW LEVEL SECURITY;
-- ALTER TABLE part_revision ENABLE ROW LEVEL SECURITY;
-- ALTER TABLE bom_line      ENABLE ROW LEVEL SECURITY;
-- CREATE POLICY part_read  ON part FOR SELECT USING (true);
-- CREATE POLICY part_write ON part FOR ALL
--     USING     (current_setting('gpbom.role', true) IN ('admin','editor'))
--     WITH CHECK(current_setting('gpbom.role', true) IN ('admin','editor'));

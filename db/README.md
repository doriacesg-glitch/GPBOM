# GPBOM — Database

PostgreSQL 15+ schema for the Green-Product BOM & Compliance system.

## Layout

```
db/
  schema.sql   -- full DDL: extensions, enums, tables, views, triggers, seed
```

## Bootstrap

```bash
createdb gpbom
psql -d gpbom -f db/schema.sql
```

All objects live in the `gpbom` schema. The bootstrap enables `pgcrypto`,
`citext`, `pg_trgm`, `btree_gist`.

## Design highlights

- **Part vs. PartRevision** — BOM lines bind to revisions so an "as-built"
  BOM at any historical timestamp is reproducible.
- **Effectivity via `tstzrange`** on `bom_line` with a GiST exclusion
  constraint that prevents overlapping duplicates on the same parent /
  child / position.
- **Homogeneous-material layer** (`part_material` → `material_substance`)
  so RoHS/REACH thresholds apply at the correct level, not at part level.
- **Substance ↔ Regulation** is many-to-many with per-row threshold and
  effective dates — regulation versions do not overwrite history.
- **Documents** are first-class (`document`, `document_test_item`) with a
  SHA-256 hash for integrity and a global `document_validity_rule` table
  that drives the expiry dashboard.
- **PCN** carries impact rows (`pcn_impact`) linking to part / revision /
  BOM line, plus before/after supplier / manufacturer / MPN fields for
  material and supplier changes.
- **Audit** — every mutation on the core tables is mirrored into
  append-only `audit_log`. The trigger reads `current_setting('gpbom.actor_id')`,
  which the API layer sets per request:
  `SET LOCAL gpbom.actor_id = '42';`
- **`part_claim`** with a partial unique index guarantees at most one
  active claim (Sanyin / Ann / Doria) per part.

## Views

- `bom_line_current` — BOM lines effective now.
- `bom_explosion`   — recursive explosion of currently-effective BOM
  with depth, cycle guard, cumulative quantity.
- `part_document_latest` — most recent document per (revision, doc_kind).
- `document_expiring` — expired or expiring-within-30-days documents.

## Not in this pass (deliberately)

- Row-Level Security policies (stubbed at the bottom of `schema.sql`).
- Application-side auth / TOTP wiring — `app_user` carries the columns,
  the flow itself belongs in the API layer.
- Full-text search config for documents (add `tsvector` column when
  document ingestion is wired up).
- Migrations tooling — this file is v0 bootstrap; adopt Alembic / Flyway
  / sqlx-migrate before the first production write.

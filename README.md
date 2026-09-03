# GPBOM — Green Product BOM & Compliance

Minimal self-hosted stack for a 3-user GP/compliance workbench.

```
db/       PostgreSQL 16 schema (single-file DDL)
api/      FastAPI + SQLAlchemy backend
web/      Vanilla HTML/JS + Tailwind CDN frontend (served by the API)
docker-compose.yml
```

## Quick start (dev)

```bash
# 1. Bring up Postgres + API
docker compose up -d --build

# 2. Seed the 3 users (Doria admin, Ann + Sanyin editors)
docker compose exec api python -m scripts.seed_users

# 3. Open the UI
open http://127.0.0.1:8000
# login: doria / ChangeMe!01   (override via env SEED_PW_DORIA etc.)
```

All ports bind to 127.0.0.1 — nothing is exposed publicly. Put Tailscale or a
VPN in front before letting Ann and Sanyin in.

## Layout

- `db/schema.sql` — full DDL, run automatically the first time the Postgres
  container starts (mounted into `/docker-entrypoint-initdb.d`).
- `api/app/` — FastAPI application:
  - `main.py` mounts routers and serves `/web/index.html`
  - `db.py` — SQLAlchemy engine, `search_path=gpbom`
  - `auth.py` — argon2 password + itsdangerous signed cookie
  - `routers/` — `auth`, `parts`, `bom`, `search`, `documents`, `claims`
- `web/` — one page (`index.html`), one stylesheet, one script.

## Security defaults

- Postgres and API both bind to `127.0.0.1` only in `docker-compose.yml`.
- Session cookie is HttpOnly + SameSite=Strict. Flip `secure=True` in
  `api/app/auth.py` once you terminate TLS.
- The API sets `SET LOCAL gpbom.actor_id` per request; every mutation on the
  main tables is mirrored into `audit_log` by triggers in the schema.
- Passwords are argon2id; TOTP columns are already in `app_user` for later.

## What's here vs. still to build

Implemented in v0.1:
- Login / logout / me
- Parts list + search (fuzzy on part_no / name)
- BOM tree (recursive, foldable, weight% of parent)
- Substance search by CAS / name
- Document expiring dashboard (highlight expired / due-soon)
- Part claims (Sanyin / Ann / Doria)

Not yet:
- Create/edit UI for PCN, documents, revisions, materials/substances
- Excel importer for BOMs
- Supplier detail page with document freshness
- Reports export (CMRT, IPC-1752A)
- TOTP + rate limiting on login
- Object storage (MinIO) for PDFs

## Tests

Add `pytest` when the first non-trivial endpoint lands; the CI hook is not
wired yet — deliberately kept out of v0.

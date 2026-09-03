"""One-shot: create initial users (Doria admin, Ann + Sanyin editors).

Run inside the api container:
    docker compose exec api python -m scripts.seed_users
"""
from __future__ import annotations

import os
import sys

sys.path.insert(0, "/app")

from sqlalchemy import text                        # noqa: E402
from app.auth import hash_password                 # noqa: E402
from app.db import engine                          # noqa: E402


USERS = [
    ("doria",  "Doria",  "admin",  os.environ.get("SEED_PW_DORIA",  "ChangeMe!01")),
    ("ann",    "Ann",    "editor", os.environ.get("SEED_PW_ANN",    "ChangeMe!02")),
    ("sanyin", "Sanyin", "editor", os.environ.get("SEED_PW_SANYIN", "ChangeMe!03")),
]


def main() -> None:
    with engine.begin() as c:
        for username, display, role, pw in USERS:
            c.execute(text("""
                INSERT INTO app_user (username, display_name, role, password_hash)
                VALUES (:u, :d, :r, :h)
                ON CONFLICT (username) DO UPDATE
                  SET display_name = EXCLUDED.display_name,
                      role         = EXCLUDED.role,
                      password_hash= EXCLUDED.password_hash
            """), {"u": username, "d": display, "r": role,
                   "h": hash_password(pw)})
            print(f"seeded {username} ({role})")

if __name__ == "__main__":
    main()

"""Database engine + session dependency."""
from __future__ import annotations

import os
from contextlib import contextmanager
from typing import Iterator

from sqlalchemy import create_engine, event, text
from sqlalchemy.orm import Session, sessionmaker

DATABASE_URL = os.environ.get(
    "DATABASE_URL",
    "postgresql+psycopg://gpbom:gpbom_dev_pw@localhost:5432/gpbom",
)

engine = create_engine(
    DATABASE_URL,
    pool_pre_ping=True,
    pool_size=5,
    max_overflow=10,
    connect_args={"options": "-c search_path=gpbom,public"},
)

SessionLocal = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)


def get_db() -> Iterator[Session]:
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


@contextmanager
def actor_session(actor_id: int | None) -> Iterator[Session]:
    """Session with gpbom.actor_id GUC bound, so audit_log records who did it."""
    db = SessionLocal()
    try:
        if actor_id is not None:
            db.execute(text("SET LOCAL gpbom.actor_id = :aid"), {"aid": str(actor_id)})
        yield db
        db.commit()
    except Exception:
        db.rollback()
        raise
    finally:
        db.close()

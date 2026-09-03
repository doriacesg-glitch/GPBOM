"""Document lists + expiring dashboard."""
from __future__ import annotations

from fastapi import APIRouter, Depends
from sqlalchemy import text
from sqlalchemy.orm import Session

from ..auth import CurrentUser, current_user
from ..db import get_db
from ..schemas import DocumentExpiring

router = APIRouter(prefix="/api/documents", tags=["documents"])


@router.get("/expiring", response_model=list[DocumentExpiring])
def expiring(db: Session = Depends(get_db),
             _: CurrentUser = Depends(current_user)):
    rows = db.execute(text("""
        SELECT id, doc_kind::text, doc_no, title,
               issue_date, expire_date, state
        FROM document_expiring
        ORDER BY expire_date
    """)).mappings().all()
    return [DocumentExpiring(**dict(r)) for r in rows]

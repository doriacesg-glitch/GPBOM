"""Part claims: Sanyin / Ann / Doria owning a follow-up."""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import text
from sqlalchemy.orm import Session

from ..auth import CurrentUser, current_user
from ..db import get_db
from ..schemas import ClaimIn

router = APIRouter(prefix="/api/claims", tags=["claims"])


@router.get("")
def list_active(db: Session = Depends(get_db),
                _: CurrentUser = Depends(current_user)):
    rows = db.execute(text("""
        SELECT c.id, c.part_id, p.part_no, p.name AS part_name,
               u.username, c.claimed_at, c.reason
        FROM part_claim c
        JOIN part p ON p.id = c.part_id
        JOIN app_user u ON u.id = c.claimed_by
        WHERE c.status='active'
        ORDER BY c.claimed_at DESC
    """)).mappings().all()
    return [dict(r) for r in rows]


@router.post("", status_code=201)
def claim(body: ClaimIn,
          db: Session = Depends(get_db),
          user: CurrentUser = Depends(current_user)):
    # release any existing active claim on this part (single active enforced by
    # partial unique index — release-then-insert is atomic within this txn)
    db.execute(text("""
        UPDATE part_claim SET status='released', released_at=now()
        WHERE part_id=:p AND status='active'
    """), {"p": body.part_id})
    row = db.execute(text("""
        INSERT INTO part_claim (part_id, claimed_by, reason)
        VALUES (:p, :u, :r) RETURNING id
    """), {"p": body.part_id, "u": user.uid, "r": body.reason}).first()
    db.commit()
    return {"id": row[0]}


@router.post("/{claim_id}/release")
def release(claim_id: int,
            db: Session = Depends(get_db),
            user: CurrentUser = Depends(current_user)):
    row = db.execute(text("""
        UPDATE part_claim SET status='released', released_at=now()
        WHERE id=:i AND status='active' RETURNING id
    """), {"i": claim_id}).first()
    if not row:
        raise HTTPException(404, "no active claim")
    db.commit()
    return {"ok": True}

"""Login / logout / me."""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Response
from sqlalchemy import text
from sqlalchemy.orm import Session

from ..auth import (CurrentUser, clear_cookie, current_user, issue_cookie,
                    verify_password)
from ..db import get_db
from ..schemas import LoginIn, Me

router = APIRouter(prefix="/api/auth", tags=["auth"])


@router.post("/login", response_model=Me)
def login(body: LoginIn, response: Response, db: Session = Depends(get_db)):
    row = db.execute(text("""
        SELECT id, username, role, is_active, password_hash
        FROM app_user WHERE username = :u
    """), {"u": body.username}).mappings().first()
    if not row or not row["is_active"] or not row["password_hash"]:
        raise HTTPException(401, "bad credentials")
    if not verify_password(row["password_hash"], body.password):
        raise HTTPException(401, "bad credentials")
    issue_cookie(response, row["id"], row["role"])
    return Me(uid=row["id"], username=row["username"], role=row["role"])


@router.post("/logout")
def logout(response: Response):
    clear_cookie(response)
    return {"ok": True}


@router.get("/me", response_model=Me)
def me(u: CurrentUser = Depends(current_user)):
    return Me(uid=u.uid, username=u.username, role=u.role)

"""Minimal session-cookie auth (argon2 password + itsdangerous signed cookie).

For 3 users on a locked-down deployment this is enough; add TOTP later.
"""
from __future__ import annotations

import os
from typing import Optional

from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError
from fastapi import Cookie, Depends, HTTPException, Response, status
from itsdangerous import BadSignature, URLSafeSerializer
from sqlalchemy import text
from sqlalchemy.orm import Session

from .db import get_db

SECRET = os.environ.get("GPBOM_SESSION_SECRET", "dev-secret-change-me")
COOKIE = "gpbom_session"
_serializer = URLSafeSerializer(SECRET, salt="gpbom-session-v1")
_hasher = PasswordHasher()


def hash_password(pw: str) -> str:
    return _hasher.hash(pw)


def verify_password(hashed: str, pw: str) -> bool:
    try:
        return _hasher.verify(hashed, pw)
    except VerifyMismatchError:
        return False


def issue_cookie(response: Response, user_id: int, role: str) -> None:
    token = _serializer.dumps({"uid": user_id, "role": role})
    response.set_cookie(
        COOKIE,
        token,
        httponly=True,
        samesite="strict",
        secure=False,   # flip to True behind TLS
        max_age=60 * 60 * 12,
        path="/",
    )


def clear_cookie(response: Response) -> None:
    response.delete_cookie(COOKIE, path="/")


class CurrentUser:
    def __init__(self, uid: int, username: str, role: str):
        self.uid = uid
        self.username = username
        self.role = role


def current_user(
    gpbom_session: Optional[str] = Cookie(default=None, alias=COOKIE),
    db: Session = Depends(get_db),
) -> CurrentUser:
    if not gpbom_session:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "not authenticated")
    try:
        payload = _serializer.loads(gpbom_session)
    except BadSignature:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "bad session")

    uid = payload["uid"]
    row = db.execute(
        text("SELECT username, role, is_active FROM app_user WHERE id = :i"),
        {"i": uid},
    ).mappings().first()
    if not row or not row["is_active"]:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "user inactive")

    # Bind actor for audit trigger on this session
    db.execute(text("SET LOCAL gpbom.actor_id = :aid"), {"aid": str(uid)})
    return CurrentUser(uid, row["username"], row["role"])


def require_role(*allowed: str):
    def _dep(u: CurrentUser = Depends(current_user)) -> CurrentUser:
        if u.role not in allowed:
            raise HTTPException(status.HTTP_403_FORBIDDEN, "forbidden")
        return u
    return _dep

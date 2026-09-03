"""Part master CRUD + list/search."""
from __future__ import annotations

from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import text
from sqlalchemy.orm import Session

from ..auth import CurrentUser, current_user, require_role
from ..db import get_db
from ..schemas import PartIn, PartOut

router = APIRouter(prefix="/api/parts", tags=["parts"])


@router.get("", response_model=list[PartOut])
def list_parts(
    q: Optional[str] = Query(None, description="fuzzy match part_no or name"),
    status_: Optional[str] = Query(None, alias="status"),
    limit: int = 100,
    offset: int = 0,
    db: Session = Depends(get_db),
    _: CurrentUser = Depends(current_user),
):
    where = []
    params: dict = {"lim": min(limit, 500), "off": offset}
    if q:
        where.append("(part_no ILIKE :q OR name ILIKE :q)")
        params["q"] = f"%{q}%"
    if status_:
        where.append("status = :st")
        params["st"] = status_
    sql = "SELECT * FROM part"
    if where:
        sql += " WHERE " + " AND ".join(where)
    sql += " ORDER BY updated_at DESC LIMIT :lim OFFSET :off"
    rows = db.execute(text(sql), params).mappings().all()
    return [PartOut(**dict(r)) for r in rows]


@router.get("/{part_id}", response_model=PartOut)
def get_part(part_id: int, db: Session = Depends(get_db),
             _: CurrentUser = Depends(current_user)):
    row = db.execute(
        text("SELECT * FROM part WHERE id = :i"), {"i": part_id}
    ).mappings().first()
    if not row:
        raise HTTPException(404, "part not found")
    return PartOut(**dict(row))


@router.post("", response_model=PartOut, status_code=201)
def create_part(
    body: PartIn,
    db: Session = Depends(get_db),
    user: CurrentUser = Depends(require_role("admin", "editor")),
):
    row = db.execute(
        text("""
            INSERT INTO part (part_no, name, kind, uom, status,
                              manufacturer_id, mpn, supplier_id, supplier_pn,
                              default_weight_g, notes, created_by, updated_by)
            VALUES (:part_no,:name,:kind,:uom,:status,
                    :manufacturer_id,:mpn,:supplier_id,:supplier_pn,
                    :default_weight_g,:notes,:uid,:uid)
            RETURNING *
        """),
        {**body.model_dump(), "uid": user.uid},
    ).mappings().first()
    db.commit()
    return PartOut(**dict(row))


@router.put("/{part_id}", response_model=PartOut)
def update_part(
    part_id: int,
    body: PartIn,
    db: Session = Depends(get_db),
    user: CurrentUser = Depends(require_role("admin", "editor")),
):
    row = db.execute(
        text("""
            UPDATE part SET
                part_no=:part_no, name=:name, kind=:kind, uom=:uom,
                status=:status, manufacturer_id=:manufacturer_id,
                mpn=:mpn, supplier_id=:supplier_id, supplier_pn=:supplier_pn,
                default_weight_g=:default_weight_g, notes=:notes,
                updated_by=:uid
            WHERE id=:id RETURNING *
        """),
        {**body.model_dump(), "id": part_id, "uid": user.uid},
    ).mappings().first()
    if not row:
        raise HTTPException(404, "part not found")
    db.commit()
    return PartOut(**dict(row))

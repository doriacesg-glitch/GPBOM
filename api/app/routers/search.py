"""Cross-product search: by substance, supplier, manufacturer, part."""
from __future__ import annotations

from typing import Optional

from fastapi import APIRouter, Depends, Query
from sqlalchemy import text
from sqlalchemy.orm import Session

from ..auth import CurrentUser, current_user
from ..db import get_db
from ..schemas import SubstanceHit

router = APIRouter(prefix="/api/search", tags=["search"])


@router.get("/substance", response_model=list[SubstanceHit])
def search_by_substance(
    cas: Optional[str] = Query(None),
    name: Optional[str] = Query(None, description="substance name (fuzzy)"),
    db: Session = Depends(get_db),
    _: CurrentUser = Depends(current_user),
):
    """Every part-material that contains the substance."""
    sql = """
        SELECT s.id       AS substance_id,
               s.name_en  AS substance_name,
               s.cas_no,
               p.id       AS part_id,
               p.part_no,
               p.name     AS part_name,
               pm.material_name,
               ms.weight_g,
               ms.ppm
        FROM material_substance ms
        JOIN substance     s  ON s.id  = ms.substance_id
        JOIN part_material pm ON pm.id = ms.part_material_id
        JOIN part_revision pr ON pr.id = pm.part_revision_id
        JOIN part           p ON p.id  = pr.part_id
        WHERE 1=1
    """
    params: dict = {}
    if cas:
        sql += " AND s.cas_no = :cas"
        params["cas"] = cas
    if name:
        sql += " AND (s.name_en ILIKE :n OR :n = ANY(s.synonyms))"
        params["n"] = f"%{name}%"
    sql += " ORDER BY p.part_no LIMIT 500"
    rows = db.execute(text(sql), params).mappings().all()
    return [SubstanceHit(**dict(r)) for r in rows]


@router.get("/supplier/{supplier_id}/parts")
def parts_by_supplier(supplier_id: int,
                      db: Session = Depends(get_db),
                      _: CurrentUser = Depends(current_user)):
    rows = db.execute(text("""
        SELECT id, part_no, name, status, last_purchase_at
        FROM part WHERE supplier_id = :s ORDER BY status, part_no
    """), {"s": supplier_id}).mappings().all()
    return [dict(r) for r in rows]

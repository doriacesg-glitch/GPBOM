"""BOM tree: nested children of a part's current revision."""
from __future__ import annotations

from decimal import Decimal
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import text
from sqlalchemy.orm import Session

from ..auth import CurrentUser, current_user
from ..db import get_db
from ..schemas import BomNode

router = APIRouter(prefix="/api/bom", tags=["bom"])


def _current_revision_id(db: Session, part_id: int) -> Optional[int]:
    row = db.execute(
        text("""
            SELECT id FROM part_revision
            WHERE part_id = :p
              AND (effective_from IS NULL OR effective_from <= current_date)
              AND (effective_to   IS NULL OR effective_to   >= current_date)
            ORDER BY effective_from DESC NULLS LAST
            LIMIT 1
        """),
        {"p": part_id},
    ).first()
    return row[0] if row else None


def _build(db: Session, revision_id: int, parent_weight_g: Optional[Decimal],
           depth: int = 0, max_depth: int = 12) -> list[BomNode]:
    if depth >= max_depth:
        return []
    rows = db.execute(
        text("""
            SELECT b.child_revision_id, b.quantity, b.weight_g_per_parent,
                   p.id AS part_id, p.part_no, p.name, p.kind, p.status
            FROM bom_line_current b
            JOIN part_revision pr ON pr.id = b.child_revision_id
            JOIN part p           ON p.id  = pr.part_id
            WHERE b.parent_revision_id = :r
            ORDER BY b.position_no NULLS LAST, p.part_no
        """),
        {"r": revision_id},
    ).mappings().all()

    out: list[BomNode] = []
    for r in rows:
        pct: Optional[float] = None
        if parent_weight_g and r["weight_g_per_parent"]:
            try:
                pct = float(r["weight_g_per_parent"]) / float(parent_weight_g) * 100
            except ZeroDivisionError:
                pct = None
        out.append(BomNode(
            revision_id=r["child_revision_id"],
            part_id=r["part_id"],
            part_no=r["part_no"],
            name=r["name"],
            kind=r["kind"],
            quantity=r["quantity"],
            weight_g_per_parent=r["weight_g_per_parent"],
            weight_pct_of_parent=pct,
            status=r["status"],
            children=_build(db, r["child_revision_id"],
                            r["weight_g_per_parent"], depth + 1, max_depth),
        ))
    return out


@router.get("/{part_id}", response_model=list[BomNode])
def bom_tree(part_id: int,
             db: Session = Depends(get_db),
             _: CurrentUser = Depends(current_user)):
    rev = _current_revision_id(db, part_id)
    if not rev:
        raise HTTPException(404, "no current revision for this part")
    parent_wg = db.execute(
        text("SELECT default_weight_g FROM part WHERE id=:i"), {"i": part_id}
    ).scalar()
    return _build(db, rev, parent_wg)

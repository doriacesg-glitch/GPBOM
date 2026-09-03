"""Pydantic request / response models."""
from __future__ import annotations

from datetime import date, datetime
from decimal import Decimal
from typing import Optional

from pydantic import BaseModel, ConfigDict, Field


class LoginIn(BaseModel):
    username: str
    password: str


class Me(BaseModel):
    uid: int
    username: str
    role: str


# ---------- Part ----------
class PartIn(BaseModel):
    part_no: str = Field(min_length=1, max_length=64)
    name: str
    kind: str = "component"
    uom: str = "pcs"
    status: str = "active"
    manufacturer_id: Optional[int] = None
    mpn: Optional[str] = None
    supplier_id: Optional[int] = None
    supplier_pn: Optional[str] = None
    default_weight_g: Optional[Decimal] = None
    notes: Optional[str] = None


class PartOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    part_no: str
    name: str
    kind: str
    uom: str
    status: str
    manufacturer_id: Optional[int]
    mpn: Optional[str]
    supplier_id: Optional[int]
    supplier_pn: Optional[str]
    default_weight_g: Optional[Decimal]
    last_purchase_at: Optional[date]
    stock_qty: Decimal
    notes: Optional[str]
    updated_at: datetime


# ---------- BOM ----------
class BomNode(BaseModel):
    revision_id: int
    part_id: int
    part_no: str
    name: str
    kind: str
    quantity: Decimal
    weight_g_per_parent: Optional[Decimal]
    weight_pct_of_parent: Optional[float]
    status: str
    children: list["BomNode"] = []


BomNode.model_rebuild()


# ---------- Substance search ----------
class SubstanceHit(BaseModel):
    substance_id: int
    substance_name: str
    cas_no: Optional[str]
    part_id: int
    part_no: str
    part_name: str
    material_name: str
    weight_g: Optional[Decimal]
    ppm: Optional[Decimal]


# ---------- Document ----------
class DocumentExpiring(BaseModel):
    id: int
    doc_kind: str
    doc_no: Optional[str]
    title: Optional[str]
    issue_date: date
    expire_date: date
    state: str


# ---------- Claim ----------
class ClaimIn(BaseModel):
    part_id: int
    reason: Optional[str] = None

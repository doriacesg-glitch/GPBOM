"""FastAPI entrypoint. Serves API + static single-page frontend."""
from __future__ import annotations

import os
from pathlib import Path

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from .routers import auth, bom, claims, documents, parts, search

app = FastAPI(title="GPBOM", version="0.1.0")

# Same-origin deployment by default; CORS only useful for dev
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:8000", "http://127.0.0.1:8000"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(auth.router)
app.include_router(parts.router)
app.include_router(bom.router)
app.include_router(search.router)
app.include_router(documents.router)
app.include_router(claims.router)


@app.get("/api/health")
def health():
    return {"ok": True}


WEB_DIR = Path(os.environ.get("GPBOM_WEB_DIR", "/app/web"))

if WEB_DIR.exists():
    app.mount("/static", StaticFiles(directory=WEB_DIR), name="static")

    @app.get("/")
    def index():
        return FileResponse(WEB_DIR / "index.html")

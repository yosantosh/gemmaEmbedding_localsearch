"""Entrypoint: `python -m app.api` serves; `uvicorn app.api:app` also works."""

from __future__ import annotations

from .api import app  # noqa: F401  (uvicorn target)
from .config import settings

if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host=settings.host, port=settings.port)

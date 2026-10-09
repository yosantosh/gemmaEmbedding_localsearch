"""Frozen-binary entry point: `pyinstaller localsearch-backend.spec`.

Keeps `app/` importable from source so dev (`python -m app.main`) and the
frozen binary share one code path. Model weights are NOT bundled — they
download to the HF cache on first run (~1.5GB).
"""

from app.api import app  # noqa: F401  (uvicorn target)
from app.config import settings


def main() -> None:
    import uvicorn

    uvicorn.run(app, host=settings.host, port=settings.port, log_level="info")


if __name__ == "__main__":
    main()

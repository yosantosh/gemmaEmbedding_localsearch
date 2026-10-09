# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller build for the localsearch backend.

Invoke from the repo root:  pyinstaller backend/localsearch-backend.spec

Model weights are NOT bundled (downloaded to the HF cache on first run).
Build with CPU-only torch to keep the binary small:
    pip install torch torchvision --index-url https://download.pytorch.org/whl/cpu
"""

import os

from PyInstaller.utils.hooks import collect_all

HERE = os.path.dirname(os.path.abspath(SPECPATH))  # noqa: F821 — provided by PyInstaller

datas, binaries, hiddenimports = [], [], []
for pkg in [
    "torch",
    "torchvision",
    "transformers",
    "sentence_transformers",
    "tokenizers",
    "huggingface_hub",
    "PIL",
    "imageio_ffmpeg",
    "fastapi",
    "uvicorn",
    "starlette",
    "pydantic",
    "numpy",
    "pypdf",
    "anyio",
    "httpx",
]:
    d, b, h = collect_all(pkg)
    datas += d
    binaries += b
    hiddenimports += h


def _keep(item):
    src = item[0].replace("\\", "/")
    return not any(
        drop in src
        for drop in ("torch/include", "torch/test", "__pycache__", ".pyi")
    )


datas = [x for x in datas if _keep(x)]
binaries = [x for x in binaries if _keep(x)]

a = Analysis(  # noqa: F821 — provided by PyInstaller
    [os.path.join(HERE, "localsearch_backend.py")],
    pathex=[HERE],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
)
pyz = PYZ(a.pure)  # noqa: F821
exe = EXE(  # noqa: F821
    pyz,
    a.scripts,
    a.binaries,
    a.datas,
    name="localsearch-backend",
    debug=False,
    strip=False,
    upx=False,
    console=True,  # server logs stay visible; windowed GUI comes later
)

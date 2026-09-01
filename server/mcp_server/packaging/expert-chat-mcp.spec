# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller spec for Windows and Linux standalone MCP Server."""

import os
from PyInstaller.utils.hooks import collect_all, collect_submodules

SPECDIR = os.path.dirname(os.path.abspath(SPEC))
SERVER_ROOT = os.path.abspath(os.path.join(SPECDIR, "..", ".."))
ENTRY = os.path.join(SERVER_ROOT, "mcp_server", "__main__.py")

datas = []
binaries = []
hiddenimports = [
    "mcp_server.app.main",
    "doc_edit.app.main",
    "gateway.app.document_mcp",
    "uvicorn.logging",
    "uvicorn.loops.auto",
    "uvicorn.protocols.http.auto",
    "uvicorn.protocols.http.h11_impl",
    "uvicorn.protocols.websockets.auto",
    "uvicorn.lifespan.on",
]
for pkg in (
    "mcp",
    "mcp_types",
    "uvicorn",
    "fastapi",
    "starlette",
    "anyio",
    "httpx",
    "httpx2",
    "pydantic",
    "openpyxl",
    "docx",
    "pptx",
    "pypdf",
):
    try:
        collected_datas, collected_binaries, collected_hidden = collect_all(pkg)
        datas += collected_datas
        binaries += collected_binaries
        hiddenimports += collected_hidden
    except Exception:
        try:
            hiddenimports += collect_submodules(pkg)
        except Exception:
            pass

a = Analysis(
    [ENTRY],
    pathex=[SERVER_ROOT],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=["tkinter", "matplotlib", "numpy.tests"],
    noarchive=False,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="expert-chat-mcp",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=True,
)
coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    name="expert-chat-mcp",
)

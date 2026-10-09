"""Vector store: one SQLite file, hybrid vector + keyword ranking.

Ranking is honest: ordering uses RRF fusion of vector-cosine rank and
FTS5 rank, but the surfaced `score` stays pure cosine so the UI never
inflates relevancy. `VectorStore` is the seam for a future LanceDB swap.
"""

from __future__ import annotations

import functools
import hashlib
import os
import re
import shutil
import sqlite3
import struct
import tempfile
import threading
from typing import NamedTuple

import numpy as np

_RRF_K = 60


def _locked(fn):
    """Serialize all SQLite access: search runs on the event-loop thread
    while background indexing writes from a worker thread."""

    @functools.wraps(fn)
    def wrapper(self, *args, **kwargs):
        with self._lock:
            return fn(self, *args, **kwargs)

    return wrapper


def _pack(vec: list[float]) -> bytes:
    return struct.pack(f"<{len(vec)}f", *vec)


def _unpack(blob: bytes) -> list[float]:
    n = len(blob) // 4
    return list(struct.unpack(f"<{n}f", blob))


def _fts_query(text: str) -> str:
    tokens = re.findall(r"[a-z0-9]+", text.lower())
    return " OR ".join(f'"{t}"' for t in tokens[:10])


class Hit(NamedTuple):
    """Ranked chunk. First five fields keep the legacy tuple order."""

    path: str
    kind: str
    snippet: str
    score: float  # pure cosine — the displayed relevancy
    mtime: float
    vec_rank: int  # 0-based meaning rank
    fts_rank: int  # 0-based keyword rank; -1 when no keyword match


class VectorStore:
    def __init__(self, path: str = "data/app.db") -> None:
        if path != ":memory:" and (d := os.path.dirname(path)):
            os.makedirs(d, exist_ok=True)
        self._db = sqlite3.connect(path, check_same_thread=False)
        self._lock = threading.RLock()
        try:
            self._db.execute("PRAGMA journal_mode=WAL")
        except sqlite3.OperationalError:
            pass  # another connection is active; keep its journal mode
        self._db.execute("PRAGMA busy_timeout=30000")
        self._db.execute("PRAGMA synchronous=NORMAL")
        if path == ":memory:":
            self._poster_tmp: tempfile.TemporaryDirectory | None = tempfile.TemporaryDirectory()
            self.poster_dir = self._poster_tmp.name
        else:
            self._poster_tmp = None
            self.poster_dir = os.path.join(os.path.dirname(os.path.abspath(path)), "posters")
            os.makedirs(self.poster_dir, exist_ok=True)
        self._db.execute(
            "CREATE TABLE IF NOT EXISTS chunks"
            "(id INTEGER PRIMARY KEY, path TEXT, kind TEXT, snippet TEXT,"
            " mtime REAL, vec BLOB)"
        )
        self._db.execute("CREATE INDEX IF NOT EXISTS idx_chunks_path ON chunks(path)")
        self._db.execute("CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT)")
        self._db.execute(
            "CREATE TABLE IF NOT EXISTS files"
            "(path TEXT PRIMARY KEY, mtime REAL, size INTEGER)"
        )
        self._db.execute(
            "CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts"
            " USING fts5(cid UNINDEXED, path, snippet)"
        )
        self._db.commit()

    @_locked
    def clear(self) -> None:
        self._db.execute("DELETE FROM chunks")
        self._db.execute("DELETE FROM chunks_fts")
        self._db.execute("DELETE FROM files")
        self._db.commit()

    @_locked
    def fingerprint(self, path: str) -> tuple[float, int] | None:
        """Last indexed (mtime, size) for path, or None if never indexed."""
        row = self._db.execute("SELECT mtime, size FROM files WHERE path=?", (path,)).fetchone()
        return (row[0], row[1]) if row else None

    @_locked
    def mark_indexed(self, path: str, mtime: float, size: int) -> None:
        self._db.execute(
            "INSERT INTO files(path,mtime,size) VALUES(?,?,?)"
            " ON CONFLICT(path) DO UPDATE SET mtime=excluded.mtime, size=excluded.size",
            (path, mtime, size),
        )

    @_locked
    def delete_path(self, path: str) -> None:
        ids = [r[0] for r in self._db.execute("SELECT id FROM chunks WHERE path=?", (path,))]
        self._db.execute("DELETE FROM chunks WHERE path=?", (path,))
        for i in ids:
            self._db.execute("DELETE FROM chunks_fts WHERE cid=?", (i,))
        self._db.execute("DELETE FROM files WHERE path=?", (path,))

    @_locked
    def prune_missing(self, keep: set[str], roots: list[str]) -> None:
        """Drop entries under roots whose files vanished since last index."""
        def _under(p: str) -> bool:
            return any(p == r or p.startswith(r + os.sep) for r in roots)

        stored = [r[0] for r in self._db.execute("SELECT DISTINCT path FROM chunks").fetchall()]
        for p in stored:
            if p not in keep and _under(p):
                self.delete_path(p)

    @_locked
    def indexed_paths(self, kind: str) -> set[str]:
        return {
            r[0]
            for r in self._db.execute(
                "SELECT DISTINCT path FROM chunks WHERE kind=?", (kind,)
            ).fetchall()
        }

    @staticmethod
    def _poster_name(file_path: str) -> str:
        return hashlib.sha1(os.path.abspath(file_path).encode()).hexdigest() + ".jpg"

    def save_poster(self, file_path: str, jpeg_path: str) -> None:
        try:
            shutil.copyfile(jpeg_path, os.path.join(self.poster_dir, self._poster_name(file_path)))
        except OSError:
            pass

    def poster_path(self, file_path: str) -> str | None:
        p = os.path.join(self.poster_dir, self._poster_name(file_path))
        return p if os.path.isfile(p) else None

    def prune_posters(self, keep: set[str]) -> None:
        want = {self._poster_name(p) for p in keep}
        try:
            for name in os.listdir(self.poster_dir):
                if name.endswith(".jpg") and name not in want:
                    os.remove(os.path.join(self.poster_dir, name))
        except OSError:
            pass

    @_locked
    def add(self, path: str, kind: str, snippet: str, mtime: float, vec: list[float]) -> None:
        cur = self._db.execute(
            "INSERT INTO chunks(path, kind, snippet, mtime, vec) VALUES(?,?,?,?,?)",
            (path, kind, snippet[:500], mtime, _pack(vec)),
        )
        self._db.execute(
            "INSERT INTO chunks_fts(cid, path, snippet) VALUES(?,?,?)",
            (cur.lastrowid, path, snippet[:500]),
        )

    @_locked
    def commit(self) -> None:
        self._db.commit()

    @_locked
    def set_roots(self, roots: list[str]) -> None:
        self._db.execute(
            "INSERT INTO meta(k,v) VALUES('roots',?) ON CONFLICT(k) DO UPDATE SET v=excluded.v",
            ("\n".join(roots),),
        )
        self._db.commit()

    @_locked
    def get_roots(self) -> list[str]:
        row = self._db.execute("SELECT v FROM meta WHERE k='roots'").fetchone()
        return row[0].split("\n") if row and row[0] else []

    @_locked
    def set_embed_id(self, model_id: str, dims: int) -> None:
        self._db.execute(
            "INSERT INTO meta(k,v) VALUES('embed_id',?)"
            " ON CONFLICT(k) DO UPDATE SET v=excluded.v",
            (f"{model_id}\n{dims}",),
        )
        self._db.commit()

    @_locked
    def get_embed_id(self) -> tuple[str, int]:
        """(model_id, dims) that produced the stored vectors.
        Returns a sentinel that never matches when absent or corrupt,
        so a damaged registry heals via rebuild instead of silent reuse."""
        row = self._db.execute("SELECT v FROM meta WHERE k='embed_id'").fetchone()
        if row:
            mid, _, dims = row[0].partition("\n")
            try:
                return (mid, int(dims))
            except ValueError:
                pass
        return ("", 0)

    @_locked
    def counts(self) -> tuple[int, int]:
        (chunks,) = self._db.execute("SELECT COUNT(*) FROM chunks").fetchone()
        (files,) = self._db.execute("SELECT COUNT(DISTINCT path) FROM chunks").fetchone()
        return files, chunks

    @_locked
    def search(
        self, query_vec: list[float], top_k: int = 10, kinds: list[str] | None = None
    ) -> list[Hit]:
        return self.hybrid("", query_vec, top_k, kinds)

    @_locked
    def hybrid(
        self,
        query_text: str,
        query_vec: list[float],
        top_k: int = 10,
        kinds: list[str] | None = None,
    ) -> list[Hit]:
        sql = "SELECT id, path, kind, snippet, mtime, vec FROM chunks"
        args: list[str] = []
        if kinds:
            sql += f" WHERE kind IN ({','.join('?' * len(kinds))})"
            args = kinds
        rows = self._db.execute(sql, args).fetchall()
        if not rows:
            return []
        mats = np.stack([np.frombuffer(r[5], dtype=np.float32) for r in rows])
        norms = np.linalg.norm(mats, axis=1)
        norms[norms == 0] = 1.0
        qv = np.asarray(query_vec, dtype=np.float32)
        qn = float(np.linalg.norm(qv)) or 1.0
        sims = np.clip((mats @ qv) / (qn * norms), 0.0, 1.0)
        order = list(np.argsort(-sims, kind="stable"))
        cos = {r[0]: float(sims[j]) for j, r in enumerate(rows)}
        vec_rank = {rows[j][0]: i for i, j in enumerate(order)}
        fts_rank: dict[int, int] = {}
        fq = _fts_query(query_text)
        if fq:
            try:
                hits = self._db.execute(
                    "SELECT cid FROM chunks_fts WHERE chunks_fts MATCH ? LIMIT 200",
                    (fq,),
                ).fetchall()
                fts_rank = {h[0]: i for i, h in enumerate(hits)}
            except sqlite3.OperationalError:
                pass  # FTS miss is non-fatal; vector order stands
        fused = {
            r[0]: 1 / (_RRF_K + vec_rank[r[0]] + 1) + (1 / (_RRF_K + fts_rank[r[0]] + 1) if r[0] in fts_rank else 0)
            for r in rows
        }
        rows.sort(key=lambda r: fused[r[0]], reverse=True)
        return [
            Hit(p, k, s, cos[i], m, vec_rank[i], fts_rank.get(i, -1))
            for i, p, k, s, m, _ in rows[:top_k]
        ]

    @_locked
    def close(self) -> None:
        self._db.close()

"""HTTP layer. Indexing runs in-process; search is embed-then-scan.

`embedder_factory` seam exists so tests can inject deterministic vectors
without downloading EmbeddingGemma 2 weights.
"""

from __future__ import annotations

import mimetypes
import os
import tempfile
import threading
from typing import Callable

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse

from .config import settings
from .indexer import FileItem, chunk_text, fmt_dur, fmt_range, media_duration, read_text_file, sample_frames, slice_audio, walk
from .models import IndexProgress, IndexRequest, IndexStatus, SearchRequest, SearchResponse, SearchResult
from .store import VectorStore


def create_app(
    store_path: str = settings.db_path,
    embedder_factory: Callable[[], object] | None = None,
    embed_id: tuple[str, int] | None = None,
) -> FastAPI:
    eid = embed_id or (settings.model_id, settings.dims)
    def _embedder():
        if embedder_factory is not None:
            return embedder_factory()
        from .embeddings import get_embedder

        return get_embedder()

    def _vision_embedder():
        if embedder_factory is not None:
            return embedder_factory()
        from .embeddings import get_vision_embedder

        return get_vision_embedder()

    def _audio_embedder():
        if embedder_factory is not None:
            return embedder_factory()
        from .embeddings import get_audio_embedder

        return get_audio_embedder()

    def _filename_vec(name: str):
        return _embedder().encode_docs([name], [name])[0]  # type: ignore[attr-defined]

    app = FastAPI(title="localsearch")
    app.add_middleware(
        CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"]
    )
    app.state.store = VectorStore(store_path)
    app.state.running = False
    app.state.cancel = False
    app.state.progress = {"running": False, "done": 0, "total": 0, "current": "", "rebuilt": False, "error": ""}

    def _status(rebuilt: bool = False) -> IndexStatus:
        store: VectorStore = app.state.store
        files, chunks = store.counts()
        return IndexStatus(
            files=files, chunks=chunks, running=app.state.running,
            roots=store.get_roots(), rebuilt=rebuilt,
        )

    @app.get("/health")
    def health() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/stats", response_model=IndexStatus)
    def stats() -> IndexStatus:
        return _status()

    class _Cancelled(Exception):
        pass

    def _do_index(
        store: VectorStore,
        items: list[FileItem],
        roots: list[str],
        rebuild: bool,
        on_item: Callable[[str], None] | None = None,
        should_stop: Callable[[], bool] | None = None,
    ) -> None:
        """Walk result → vectors. Shared by sync and background indexing."""

        done = 0

        def tick(path: str) -> None:
            nonlocal done
            done += 1
            if done % 25 == 0:
                store.commit()  # crash/kill keeps partial progress
            if on_item is not None:
                on_item(path)

        def check_cancel() -> None:
            if should_stop is not None and should_stop():
                raise _Cancelled

        embedder = _embedder()
        seen: set[str] = set()
        images: list[FileItem] = []
        videos: list[FileItem] = []
        audios: list[FileItem] = []
        for item in items:
            check_cancel()
            seen.add(item.path)
            if not rebuild:
                if store.fingerprint(item.path) == (item.mtime, item.size):
                    tick(item.path)
                    continue  # unchanged — skip embedding entirely
                store.delete_path(item.path)
            if item.kind in ("text", "pdf"):
                if item.size > settings.max_text_bytes:
                    store.mark_indexed(item.path, item.mtime, item.size)
                    tick(item.path)
                    continue  # too big to embed; recorded for fast skips
                try:
                    text = read_text_file(item.path)
                except OSError:
                    tick(item.path)
                    continue
                chunks = chunk_text(text, settings.chunk_chars, settings.chunk_overlap)
                if not chunks:
                    tick(item.path)
                    continue
                base = os.path.basename(item.path)
                for j in range(0, len(chunks), settings.index_text_batch):
                    check_cancel()
                    part = chunks[j : j + settings.index_text_batch]
                    vecs = embedder.encode_docs([base] * len(part), part)
                    for snippet, vec in zip(part, vecs):
                        store.add(item.path, item.kind, snippet, item.mtime, vec)
                store.mark_indexed(item.path, item.mtime, item.size)
                tick(item.path)
            elif item.kind == "image":
                images.append(item)  # content-embedded in batches below
            elif item.kind == "video":
                videos.append(item)  # one mean-pooled vector per file below
            elif item.kind == "audio":
                audios.append(item)  # one vector per window below
        for i in range(0, len(images), settings.index_image_batch):
            check_cancel()
            batch = images[i : i + settings.index_image_batch]
            vecs = _vision_embedder().encode_images([it.path for it in batch])  # type: ignore[attr-defined]
            for item, vec in zip(batch, vecs):
                store.add(item.path, item.kind, os.path.basename(item.path),
                          item.mtime, vec)
                store.mark_indexed(item.path, item.mtime, item.size)
                tick(item.path)
        for item in videos:
            check_cancel()
            base = os.path.basename(item.path)
            with tempfile.TemporaryDirectory() as tmp:
                frames = sample_frames(item.path, settings.index_video_frames, tmp)
                if frames:
                    store.save_poster(item.path, frames[0])
                try:
                    vec = _vision_embedder().encode_video(frames) if frames else _filename_vec(base)  # type: ignore[attr-defined]
                except Exception:
                    vec = _filename_vec(base)  # unreadable video stays findable
            dur = media_duration(item.path)
            snippet = f"[{fmt_dur(dur)}] {base}" if dur else base
            store.add(item.path, item.kind, snippet, item.mtime, vec)
            store.mark_indexed(item.path, item.mtime, item.size)
            tick(item.path)
        store.prune_posters(store.indexed_paths("video"))
        for item in audios:
            check_cancel()
            base = os.path.basename(item.path)
            with tempfile.TemporaryDirectory() as tmp:
                wins = slice_audio(item.path, settings.index_audio_window_sec, tmp)
                if not wins:
                    store.add(item.path, item.kind, base, item.mtime, _filename_vec(base))
                else:
                    for k in range(0, len(wins), settings.index_audio_batch):
                        check_cancel()
                        wb = wins[k : k + settings.index_audio_batch]
                        try:
                            avecs = _audio_embedder().encode_audio([w for w, _, _ in wb])  # type: ignore[attr-defined]
                        except Exception:
                            avecs = []
                            for (w, _, _) in wb:  # retry singly; worst case filename
                                try:
                                    avecs.append(_audio_embedder().encode_audio([w])[0])  # type: ignore[attr-defined]
                                except Exception:
                                    avecs.append(_filename_vec(base))
                        for (w, s, e), vec in zip(wb, avecs):
                            store.add(item.path, item.kind, f"[{fmt_range(s, e)}] {base}",
                                      item.mtime, vec)
            store.mark_indexed(item.path, item.mtime, item.size)
            tick(item.path)
        if not rebuild:
            store.prune_missing(seen, roots)
        store.commit()

    def _index_in_background(items: list[FileItem], roots: list[str], rebuild: bool) -> None:
        store: VectorStore = app.state.store
        try:
            def tick(path: str) -> None:
                p = app.state.progress
                p["done"] += 1
                p["current"] = os.path.basename(path)

            _do_index(
                store, items, roots, rebuild, on_item=tick,
                should_stop=lambda: app.state.cancel,
            )
        except _Cancelled:
            store.commit()  # keep partial work; next run resumes via fingerprints
            app.state.progress["error"] = "cancelled by user"
        except Exception as e:
            store.commit()
            app.state.progress["error"] = str(e)[:300]
        finally:
            app.state.running = False
            app.state.progress["running"] = False

    @app.post("/index/cancel")
    def cancel_index() -> dict[str, bool]:
        app.state.cancel = True
        return {"cancelling": app.state.running}

    @app.post("/index", response_model=IndexStatus)
    def index(req: IndexRequest) -> IndexStatus:
        if app.state.running:
            raise HTTPException(409, "index already running")
        missing = [r for r in req.roots if not os.path.isdir(r)]
        if missing:
            raise HTTPException(422, f"roots not found: {missing}")
        store: VectorStore = app.state.store
        _, n_chunks = store.counts()
        auto_rebuild = n_chunks > 0 and store.get_embed_id() != eid
        rebuild = req.reset or auto_rebuild
        if rebuild:
            store.clear()
        store.set_embed_id(*eid)
        store.set_roots(req.roots)
        items = list({it.path: it for it in walk(req.roots)}.values())
        app.state.cancel = False
        if req.background:
            app.state.running = True
            app.state.progress = {
                "running": True, "done": 0, "total": len(items),
                "current": "", "rebuilt": auto_rebuild, "error": "",
            }
            threading.Thread(
                target=_index_in_background, args=(items, req.roots, rebuild), daemon=True
            ).start()
            return _status()
        _do_index(store, items, req.roots, rebuild)
        return _status(rebuilt=auto_rebuild)

    @app.post("/search", response_model=SearchResponse)
    def search(req: SearchRequest) -> SearchResponse:
        store: VectorStore = app.state.store
        root = os.path.realpath(req.root) + os.sep if req.root else ""
        q = _embedder().encode_query(req.query)  # type: ignore[attr-defined]
        hits = store.hybrid(req.query, q, req.top_k, req.kinds or None)
        return SearchResponse(
            query=req.query,
            results=[
                SearchResult(
                    path=h.path, kind=h.kind, snippet=h.snippet,
                    score=round(h.score, 4), mtime=h.mtime,
                    vec_rank=h.vec_rank, fts_rank=h.fts_rank,
                )
                for h in hits
                if not root or h.path == req.root or h.path.startswith(root)
            ],
        )

    @app.get("/index/progress", response_model=IndexProgress)
    def index_progress() -> IndexProgress:
        return IndexProgress(**app.state.progress)

    def _resolve(path: str) -> str:
        """Absolute path guarded to indexed roots (403 otherwise).
        Uses realpath so a symlink inside a root cannot escape it."""
        roots = app.state.store.get_roots()
        abs_path = os.path.realpath(path)
        if not any(
            abs_path == os.path.realpath(r) or abs_path.startswith(os.path.realpath(r) + os.sep)
            for r in roots
        ):
            raise HTTPException(403, "path outside indexed roots")
        return abs_path

    @app.get("/file")
    def serve_file(path: str) -> FileResponse:
        abs_path = _resolve(path)
        if not os.path.isfile(abs_path):
            raise HTTPException(404, "not found")
        mime, _ = mimetypes.guess_type(abs_path)
        return FileResponse(abs_path, media_type=mime or "application/octet-stream")

    @app.get("/poster")
    def poster(path: str) -> FileResponse:
        store: VectorStore = app.state.store
        _resolve(path)
        p = store.poster_path(path)
        if not p:
            raise HTTPException(404, "no poster")
        return FileResponse(p, media_type="image/jpeg")

    return app


app = create_app()

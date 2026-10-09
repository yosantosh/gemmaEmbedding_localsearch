"""API end-to-end with a deterministic fake embedder (no weights)."""

import re

from fastapi.testclient import TestClient

from app.api import create_app

_TOKENS = ["cnn", "notes", "blue", "tshirt", "photo", "lecture", "random",
           "dog", "guitar", "crowd"]


def _vec(text: str) -> list[float]:
    words = re.findall(r"[a-z]+", text.lower())
    words = ["tshirt" if w in ("shirt", "tshirt", "t-shirt") else w for w in words]
    v = [float(words.count(t)) for t in _TOKENS]
    n = sum(x * x for x in v) ** 0.5 or 1.0
    return [x / n for x in v]


class FakeEmbedder:
    def encode_query(self, q: str) -> list[float]:
        return _vec(q)

    def encode_docs(self, titles: list[str], texts: list[str]) -> list[list[float]]:
        return [_vec(f"{t} {c}") for t, c in zip(titles, texts)]

    def encode_images(self, paths: list[str]) -> list[list[float]]:
        import os

        return [_vec(os.path.basename(p)) for p in paths]

    def encode_video(self, frame_paths: list[str]) -> list[float]:
        return _vec("video")

    def encode_audio(self, wav_paths: list[str]) -> list[list[float]]:
        return [_vec("audio") for _ in wav_paths]


class CountingEmbedder(FakeEmbedder):
    def __init__(self) -> None:
        self.doc_calls = 0

    def encode_docs(self, titles: list[str], texts: list[str]) -> list[list[float]]:
        self.doc_calls += len(texts)
        return super().encode_docs(titles, texts)


def _client() -> TestClient:
    app = create_app(":memory:", embedder_factory=FakeEmbedder)
    return TestClient(app)


def test_index_search_roundtrip(tmp_path):
    (tmp_path / "cnn_notes.txt").write_text("CNN convolutional lecture: kernels and notes")
    (tmp_path / "blue_tshirt.jpg").write_bytes(b"\x89PNG")
    (tmp_path / "random.txt").write_text("grocery list apples random")
    c = _client()
    r = c.post("/index", json={"roots": [str(tmp_path)], "reset": True})
    assert r.status_code == 200, r.text
    assert r.json()["files"] == 3

    r = c.post("/search", json={"query": "CNN notes", "top_k": 3})
    assert r.status_code == 200
    paths = [h["path"] for h in r.json()["results"]]
    assert paths[0].endswith("cnn_notes.txt")

    r = c.post("/search", json={"query": "blue tshirt photo", "top_k": 3})
    paths = [h["path"] for h in r.json()["results"]]
    assert paths[0].endswith("blue_tshirt.jpg")


def test_hybrid_surfaces_keyword_hit(tmp_path):
    # "convolutional" appears verbatim but shares no fake-embedding token
    # weight with the query beyond cnn; FTS must keep it competitive.
    (tmp_path / "a.txt").write_text("convolutional kernels stride padding")
    (tmp_path / "b.txt").write_text("random grocery apples")
    c = _client()
    c.post("/index", json={"roots": [str(tmp_path)], "reset": True})
    r = c.post("/search", json={"query": "convolutional", "top_k": 2})
    assert r.json()["results"][0]["path"].endswith("a.txt")


def test_file_serve_guarded(tmp_path):
    f = tmp_path / "doc.txt"
    f.write_text("hello")
    c = _client()
    c.post("/index", json={"roots": [str(tmp_path)], "reset": True})
    assert c.get("/file", params={"path": str(f)}).status_code == 200
    assert c.get("/file", params={"path": "/etc/hostname"}).status_code == 403
    assert c.get("/file", params={"path": str(tmp_path / "nope.txt")}).status_code == 404


def test_reindex_skips_unchanged_no_dupes(tmp_path):
    (tmp_path / "notes.txt").write_text("cnn lecture notes here")
    emb = CountingEmbedder()
    c = TestClient(create_app(":memory:", embedder_factory=lambda: emb))
    assert c.post("/index", json={"roots": [str(tmp_path)], "reset": True}).status_code == 200
    first_calls, first_chunks = emb.doc_calls, c.get("/stats").json()["chunks"]
    assert first_calls > 0
    emb.doc_calls = 0
    r = c.post("/index", json={"roots": [str(tmp_path)], "reset": False})
    assert r.status_code == 200
    assert emb.doc_calls == 0  # nothing re-embedded
    assert r.json()["chunks"] == first_chunks  # and nothing duplicated


def test_modified_file_reindexed(tmp_path):
    f = tmp_path / "notes.txt"
    f.write_text("cnn lecture notes here")
    emb = CountingEmbedder()
    c = TestClient(create_app(":memory:", embedder_factory=lambda: emb))
    c.post("/index", json={"roots": [str(tmp_path)], "reset": True})
    f.write_text("cnn lecture notes here plus more random grocery apples extra words")
    emb.doc_calls = 0
    c.post("/index", json={"roots": [str(tmp_path)], "reset": False})
    assert emb.doc_calls > 0
    hits = c.post("/search", json={"query": "grocery", "top_k": 1}).json()["results"]
    assert hits and "grocery" in hits[0]["snippet"]


def test_deleted_file_pruned(tmp_path):
    f = tmp_path / "notes.txt"
    f.write_text("cnn lecture notes here")
    c = _client()
    c.post("/index", json={"roots": [str(tmp_path)], "reset": True})
    assert c.get("/stats").json()["files"] == 1
    f.unlink()
    r = c.post("/index", json={"roots": [str(tmp_path)], "reset": False})
    assert r.json()["files"] == 0
    assert c.post("/search", json={"query": "cnn", "top_k": 5}).json()["results"] == []


class ContentEmbedder(FakeEmbedder):
    """Simulates vision signal: every image embeds as 'blue' content,
    regardless of filename — proves ranking uses the vision path."""

    def __init__(self) -> None:
        self.image_calls = 0

    def encode_images(self, paths: list[str]) -> list[list[float]]:
        self.image_calls += len(paths)
        return [_vec("blue") for _ in paths]


def test_image_ranked_by_content_not_filename(tmp_path):
    (tmp_path / "IMG_0001.jpg").write_bytes(b"\x89PNG")
    (tmp_path / "notes.txt").write_text("grocery list apples random")
    emb = ContentEmbedder()
    c = TestClient(create_app(":memory:", embedder_factory=lambda: emb))
    c.post("/index", json={"roots": [str(tmp_path)], "reset": True})
    assert emb.image_calls == 1  # vision path taken, not filename path
    hits = c.post("/search", json={"query": "blue", "top_k": 2}).json()["results"]
    assert hits[0]["path"].endswith("IMG_0001.jpg")


def test_embed_match_keeps_incremental_skip(tmp_path):
    (tmp_path / "notes.txt").write_text("cnn lecture notes here")
    emb = CountingEmbedder()
    c = TestClient(
        create_app(str(tmp_path) + ".db", embedder_factory=lambda: emb, embed_id=("m", 7))
    )
    assert c.post("/index", json={"roots": [str(tmp_path)], "reset": False}).json()["rebuilt"] is False
    emb.doc_calls = 0
    r = c.post("/index", json={"roots": [str(tmp_path)], "reset": False})
    assert r.json()["rebuilt"] is False
    assert emb.doc_calls == 0


def test_embed_mismatch_forces_rebuild(tmp_path):
    (tmp_path / "notes.txt").write_text("cnn lecture notes here")
    db = str(tmp_path) + ".db"
    emb = CountingEmbedder()
    c1 = TestClient(create_app(db, embedder_factory=lambda: emb, embed_id=("m1", 7)))
    assert c1.post("/index", json={"roots": [str(tmp_path)], "reset": False}).json()["rebuilt"] is False
    emb.doc_calls = 0
    c2 = TestClient(create_app(db, embedder_factory=lambda: emb, embed_id=("m2", 7)))
    r = c2.post("/index", json={"roots": [str(tmp_path)], "reset": False})
    assert r.json()["rebuilt"] is True
    assert emb.doc_calls > 0  # re-embedded despite unchanged files
    assert r.json()["chunks"] == 1  # rebuilt, not duplicated


class VideoContentEmbedder(FakeEmbedder):
    def __init__(self) -> None:
        self.video_calls = 0

    def encode_video(self, frame_paths: list[str]) -> list[float]:
        self.video_calls += 1
        return _vec("dog")


class AudioContentEmbedder(FakeEmbedder):
    def __init__(self) -> None:
        self.audio_calls = 0

    def encode_audio(self, wav_paths: list[str]) -> list[list[float]]:
        self.audio_calls += len(wav_paths)
        return [_vec("guitar") if i == 0 else _vec("crowd") for i in range(len(wav_paths))]


def test_video_ranked_by_content(tmp_path, monkeypatch):
    import app.api as api_mod

    (tmp_path / "VID_0001.mp4").write_bytes(b"\x00")
    monkeypatch.setattr(api_mod, "sample_frames", lambda p, n, d: ["f1.jpg", "f2.jpg"])
    emb = VideoContentEmbedder()
    c = TestClient(create_app(":memory:", embedder_factory=lambda: emb))
    c.post("/index", json={"roots": [str(tmp_path)], "reset": True})
    assert emb.video_calls == 1
    hits = c.post("/search", json={"query": "dog", "top_k": 2}).json()["results"]
    assert hits[0]["path"].endswith("VID_0001.mp4")


def test_unreadable_video_falls_back_to_filename(tmp_path, monkeypatch):
    import app.api as api_mod

    (tmp_path / "dog_trip.mp4").write_bytes(b"\x00")
    monkeypatch.setattr(api_mod, "sample_frames", lambda p, n, d: [])
    c = _client()
    r = c.post("/index", json={"roots": [str(tmp_path)], "reset": True})
    assert r.json()["files"] == 1
    hits = c.post("/search", json={"query": "dog", "top_k": 1}).json()["results"]
    assert hits[0]["path"].endswith("dog_trip.mp4")


def test_audio_windows_ranked_by_segment(tmp_path, monkeypatch):
    import app.api as api_mod

    (tmp_path / "jam.mp3").write_bytes(b"\x00")
    monkeypatch.setattr(
        api_mod, "slice_audio",
        lambda p, w, d: [(f"{d}/w0.wav", 0.0, 240.0), (f"{d}/w1.wav", 240.0, 480.0)],
    )
    emb = AudioContentEmbedder()
    c = TestClient(create_app(":memory:", embedder_factory=lambda: emb))
    r = c.post("/index", json={"roots": [str(tmp_path)], "reset": True})
    assert emb.audio_calls == 2
    assert r.json()["chunks"] == 2
    hits = c.post("/search", json={"query": "guitar", "top_k": 2}).json()["results"]
    assert hits[0]["snippet"].startswith("[00:00-04:00]")
    hits = c.post("/search", json={"query": "crowd", "top_k": 2}).json()["results"]
    assert hits[0]["snippet"].startswith("[04:00-08:00]")


def test_unreadable_audio_falls_back_to_filename(tmp_path, monkeypatch):
    import app.api as api_mod

    (tmp_path / "guitar_jam.mp3").write_bytes(b"\x00")
    monkeypatch.setattr(api_mod, "slice_audio", lambda p, w, d: [])
    c = _client()
    assert c.post("/index", json={"roots": [str(tmp_path)], "reset": True}).json()["files"] == 1
    hits = c.post("/search", json={"query": "guitar", "top_k": 1}).json()["results"]
    assert hits[0]["path"].endswith("guitar_jam.mp3")


def test_background_index_reports_progress(tmp_path):
    import time

    (tmp_path / "a.txt").write_text("cnn notes here")
    (tmp_path / "b.txt").write_text("grocery apples random")
    c = _client()
    r = c.post("/index", json={"roots": [str(tmp_path)], "reset": True, "background": True})
    assert r.status_code == 200, r.text
    # The 2-file fake job may already be done: poll either way.
    prog = c.get("/index/progress").json()
    for _ in range(200):
        if not prog["running"]:
            break
        time.sleep(0.05)
        prog = c.get("/index/progress").json()
    assert prog["running"] is False
    assert prog["total"] == 2
    assert prog["done"] == 2
    assert c.get("/stats").json()["files"] == 2
    # second run while idle is accepted again
    assert c.post("/index", json={"roots": [str(tmp_path)], "reset": True}).status_code == 200


def test_video_poster_served_and_guarded(tmp_path, monkeypatch):
    import app.api as api_mod

    vid = tmp_path / "clip.mp4"
    vid.write_bytes(b"\x00")
    frame = tmp_path / "frame.jpg"
    frame.write_bytes(b"JPEG-BYTES")
    monkeypatch.setattr(api_mod, "sample_frames", lambda p, n, d: [str(frame)])
    monkeypatch.setattr(api_mod, "media_duration", lambda p: 61.0)
    c = _client()
    c.post("/index", json={"roots": [str(tmp_path)], "reset": True})
    r = c.get("/poster", params={"path": str(vid)})
    assert r.status_code == 200
    assert r.content == b"JPEG-BYTES"
    assert c.get("/poster", params={"path": "/etc/hostname"}).status_code == 403
    assert c.get("/poster", params={"path": str(tmp_path / "missing.mp4")}).status_code == 404


def test_rank_fields_explain_match(tmp_path):
    (tmp_path / "cnn_notes.txt").write_text("CNN convolutional lecture: kernels and notes")
    (tmp_path / "random.txt").write_text("grocery list apples random")
    c = _client()
    c.post("/index", json={"roots": [str(tmp_path)], "reset": True})
    hits = c.post("/search", json={"query": "CNN notes", "top_k": 2}).json()["results"]
    assert hits[0]["path"].endswith("cnn_notes.txt")
    assert hits[0]["vec_rank"] == 0
    assert hits[0]["fts_rank"] == 0
    assert hits[1]["fts_rank"] == -1  # no shared words: meaning only


class SlowEmbedder(FakeEmbedder):
    def encode_docs(self, titles, texts):
        import time

        time.sleep(0.2)
        return super().encode_docs(titles, texts)


def test_cancel_stops_background_index(tmp_path):
    import time

    for i in range(10):
        (tmp_path / f"f{i}.txt").write_text(f"cnn notes file number {i}")
    emb = SlowEmbedder()
    c = TestClient(create_app(":memory:", embedder_factory=lambda: emb))
    assert c.post("/index", json={"roots": [str(tmp_path)], "reset": True, "background": True}).status_code == 200
    for _ in range(100):
        if c.get("/index/progress").json()["done"] >= 1:
            break
        time.sleep(0.05)
    assert c.post("/index/cancel").json() == {"cancelling": True}
    prog = {"running": True}
    for _ in range(200):
        prog = c.get("/index/progress").json()
        if not prog["running"]:
            break
        time.sleep(0.05)
    assert prog["running"] is False
    assert prog["error"] == "cancelled by user"
    assert prog["done"] < 10
    # resume completes everything; partial work was committed
    r = c.post("/index", json={"roots": [str(tmp_path)], "reset": False})
    assert r.json()["files"] == 10


class BoomEmbedder(FakeEmbedder):
    def encode_docs(self, titles, texts):
        raise RuntimeError("boom")


def test_worker_error_surfaces_in_progress(tmp_path):
    import time

    (tmp_path / "a.txt").write_text("cnn notes")
    c = TestClient(create_app(":memory:", embedder_factory=BoomEmbedder))
    c.post("/index", json={"roots": [str(tmp_path)], "reset": True, "background": True})
    prog = {"running": True}
    for _ in range(200):
        prog = c.get("/index/progress").json()
        if not prog["running"]:
            break
        time.sleep(0.05)
    assert prog["running"] is False
    assert "boom" in prog["error"]


def test_missing_roots_rejected(tmp_path):
    c = _client()
    r = c.post("/index", json={"roots": [str(tmp_path / "nope")], "reset": True})
    assert r.status_code == 422


def test_overlapping_roots_no_dupes(tmp_path):
    (tmp_path / "notes.txt").write_text("cnn lecture notes here")
    c = _client()
    r = c.post("/index", json={"roots": [str(tmp_path), str(tmp_path)], "reset": True})
    assert r.json()["files"] == 1
    assert r.json()["chunks"] == 1


def test_big_file_skipped_not_read(tmp_path):
    (tmp_path / "big.txt").write_bytes(b"x" * (11 * 1024 * 1024))
    (tmp_path / "small.txt").write_text("cnn notes")
    emb = CountingEmbedder()
    c = TestClient(create_app(":memory:", embedder_factory=lambda: emb))
    r = c.post("/index", json={"roots": [str(tmp_path)], "reset": True})
    assert r.json()["files"] == 1  # big file recorded but vectorless
    assert r.json()["chunks"] == 1  # only the small file produced vectors
    emb.doc_calls = 0
    c.post("/index", json={"roots": [str(tmp_path)], "reset": False})
    assert emb.doc_calls == 0  # big file stays skipped without re-reading


def test_symlink_cannot_escape_roots(tmp_path):
    secret = tmp_path / "secret.txt"
    secret.write_text("top secret")
    root = tmp_path / "root"
    root.mkdir()
    (root / "link.txt").symlink_to(secret)
    (root / "real.txt").write_text("cnn notes")
    c = _client()
    c.post("/index", json={"roots": [str(root)], "reset": True})
    assert c.get("/file", params={"path": str(root / "link.txt")}).status_code == 403
    assert c.get("/file", params={"path": str(root / "real.txt")}).status_code == 200


def test_search_root_filter_is_strict(tmp_path):
    b = tmp_path / "b"
    bc = tmp_path / "bc"
    b.mkdir()
    bc.mkdir()
    (b / "in.txt").write_text("cnn notes here")
    (bc / "out.txt").write_text("cnn notes here")
    c = _client()
    c.post("/index", json={"roots": [str(tmp_path)], "reset": True})
    hits = c.post("/search", json={"query": "cnn", "top_k": 5, "root": str(b)}).json()["results"]
    assert len(hits) == 1
    assert hits[0]["path"].endswith("b/in.txt")


def test_encode_images_single_result_shape(tmp_path):
    import numpy as np
    from PIL import Image

    from app import embeddings as E

    p = tmp_path / "a.png"
    Image.new("RGB", (8, 8)).save(p)
    emb = E.Embedder.__new__(E.Embedder)
    emb._has_vision = True

    class M:
        def encode(self, imgs, normalize_embeddings=True):
            assert len(imgs) == 1
            return np.ones(768, dtype=np.float32)  # 1-D, like the ST scalar path

    emb._model = M()
    assert len(emb.encode_images([str(p)])) == 1

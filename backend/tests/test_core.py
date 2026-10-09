import math

from app.embeddings import cosine, doc_prefix, query_prefix, truncate
from app.indexer import chunk_text, classify
from app.store import VectorStore


def test_prefixes_match_model_card():
    assert query_prefix("cnn notes") == "task: search result | query: cnn notes"
    assert doc_prefix("", "x") == "title: none | text: x"
    assert doc_prefix("a", "x") == "title: a | text: x"


def test_cosine_bounds_and_identity():
    assert cosine([1, 0], [1, 0]) == 1.0
    assert cosine([1, 0], [0, 1]) == 0.0
    assert 0.0 <= cosine([1, 2], [2, 1]) <= 1.0
    assert cosine([], []) == 0.0


def test_truncate_renormalizes():
    v = truncate([3.0, 4.0, 12.0], 2)
    assert len(v) == 2
    assert math.isclose(math.sqrt(sum(x * x for x in v)), 1.0)


def test_chunking_overlap():
    chunks = chunk_text("a " * 1000, size=100, overlap=20)
    assert len(chunks) > 1
    assert all(len(c) <= 100 for c in chunks)


def test_classify():
    assert classify("a.png") == "image"
    assert classify("a.pdf") == "pdf"
    assert classify("a.py") == "text"
    assert classify("a.zip") == "skip"


def test_store_ranking_is_cosine_order():
    s = VectorStore(":memory:")
    s.add("/a.txt", "text", "cnn notes", 0.0, [1.0, 0.0])
    s.add("/b.txt", "text", "unrelated", 0.0, [0.0, 1.0])
    s.commit()
    hits = s.search([1.0, 0.0], top_k=2)
    assert hits[0][0] == "/a.txt"
    assert hits[0][3] > hits[1][3]
    s.close()


def test_embedder_pool_selects_modalities():
    from unittest.mock import patch

    from app import embeddings as E

    E.get_embedder.cache_clear()
    E.get_vision_embedder.cache_clear()
    try:
        with patch.object(E, "Embedder") as M:
            E.get_embedder()
            assert M.call_args.kwargs.get("with_vision") is False
        with patch.object(E, "Embedder") as M:
            E.get_vision_embedder()
            assert M.call_args.kwargs.get("with_vision") is True
    finally:
        E.get_embedder.cache_clear()
        E.get_vision_embedder.cache_clear()


def test_encode_images_guard_without_vision():
    from app import embeddings as E

    emb = E.Embedder.__new__(E.Embedder)
    emb._has_vision = False
    try:
        emb.encode_images(["x.jpg"])
        raise AssertionError("guard did not fire")
    except RuntimeError:
        pass


def test_mean_pool_renormalizes():
    from app.embeddings import mean_pool

    v = mean_pool([[1.0, 0.0], [0.0, 1.0]])
    assert math.isclose(v[0], v[1])
    assert math.isclose(sum(x * x for x in v), 1.0)


def test_fmt_range():
    from app.indexer import fmt_range

    assert fmt_range(0, 240) == "00:00-04:00"
    assert fmt_range(754, 900) == "12:34-15:00"


def test_classify_video_audio():
    assert classify("a.mp4") == "video"
    assert classify("a.mkv") == "video"
    assert classify("a.mp3") == "audio"


def test_fmt_dur():
    from app.indexer import fmt_dur

    assert fmt_dur(0) == "00:00"
    assert fmt_dur(151) == "02:31"

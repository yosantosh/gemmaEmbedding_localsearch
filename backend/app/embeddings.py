"""EmbeddingGemma 2 wrapper.

Single choke point for all prompt-prefix, dtype and normalization rules
from the model card. Nothing else in the codebase may hand-roll prefixes.

Model is lazy-loaded so tests and `--help` never download weights.
"""

from __future__ import annotations

import math
from functools import lru_cache


def query_prefix(q: str) -> str:
    return f"task: search result | query: {q.strip()}"


def doc_prefix(title: str, content: str) -> str:
    t = title.strip() or "none"
    return f"title: {t} | text: {content.strip()}"


def cosine(a: list[float] | tuple[float, ...], b: list[float] | tuple[float, ...]) -> float:
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    if na == 0 or nb == 0:
        return 0.0
    return max(0.0, min(1.0, dot / (na * nb)))


def truncate(vec: list[float], dim: int) -> list[float]:
    """MRL truncation: keep leading dims, then re-normalize (model card rule)."""
    cut = vec[:dim]
    n = math.sqrt(sum(x * x for x in cut))
    if n == 0:
        return cut
    return [x / n for x in cut]


def mean_pool(vecs: list[list[float]]) -> list[float]:
    """Mean + re-normalize. Pure function — unit tested."""
    if not vecs:
        raise ValueError("no vectors to pool")
    mean = [sum(v[i] for v in vecs) / len(vecs) for i in range(len(vecs[0]))]
    n = math.sqrt(sum(x * x for x in mean))
    if n == 0:
        raise ValueError("zero vectors")
    return [x / n for x in mean]


class Embedder:
    """Thin wrapper over SentenceTransformer. One instance per process.

    Encoders are modular: construct with only the modalities you use.
    """

    def __init__(
        self,
        model_id: str = "google/embeddinggemma-2",
        with_vision: bool = True,
        with_audio: bool = False,
        vision_tokens: int = 280,
    ) -> None:
        import torch
        from sentence_transformers import SentenceTransformer

        dtype = torch.bfloat16 if torch.cuda.is_bf16_supported() else torch.float32
        self._has_vision = with_vision
        self._has_audio = with_audio
        self._model = SentenceTransformer(
            model_id,
            model_kwargs={"torch_dtype": dtype},
            config_kwargs={
                **({} if with_vision else {"vision_config": None}),
                **({} if with_audio else {"audio_config": None}),
            },
        )
        if with_vision and vision_tokens != 280:
            # Model-card supported range 70-1120. Mutated post-load: the
            # processor reads image_seq_length at encode time. Verified live
            # by timing + cosine drift, not assumed.
            processor = getattr(self._model[0], "processor", None)
            if processor is not None and hasattr(processor, "image_seq_length"):
                processor.image_seq_length = vision_tokens

    @staticmethod
    def _finish(vec, dim: int) -> list[float]:
        v = [float(x) for x in vec]
        return truncate(v, dim) if dim != len(v) else v

    def encode_query(self, query: str, dim: int = 768) -> list[float]:
        return self._finish(
            self._model.encode(query_prefix(query), normalize_embeddings=True), dim
        )

    def encode_docs(self, titles: list[str], texts: list[str], dim: int = 768) -> list[list[float]]:
        inputs = [doc_prefix(t, c) for t, c in zip(titles, texts)]
        vecs = self._model.encode(inputs, normalize_embeddings=True)
        return [self._finish(v, dim) for v in vecs]

    def encode_images(self, paths: list[str], dim: int = 768) -> list[list[float]]:
        """Content embeddings via the vision encoder. Files that fail to
        decode fall back to filename embedding so one corrupt file never
        breaks a batch. Images are downscaled to 1024px first: the vision
        encoder resizes internally anyway, and gigapixel panoramas would
        otherwise blow up RAM on decode."""
        if not self._has_vision:
            raise RuntimeError("vision encoder not loaded; use get_vision_embedder()")
        from PIL import Image

        import numpy as np

        good_idx, imgs = [], []
        for i, p in enumerate(paths):
            try:
                with Image.open(p) as im:
                    im.load()
                    rgb = im.convert("RGB")
                    rgb.thumbnail((1024, 1024))
                    imgs.append(rgb)
                good_idx.append(i)
            except Exception:
                continue
        encoded_rows: list = []
        if imgs:
            raw = self._model.encode(imgs, normalize_embeddings=True)
            encoded_rows = [r for r in np.atleast_2d(raw)]
        out: list[list[float] | None] = [None] * len(paths)
        for i, v in zip(good_idx, encoded_rows):
            out[i] = self._finish(v, dim)
        for i, p in enumerate(paths):
            if out[i] is None:
                import os

                base = os.path.basename(p)
                out[i] = self.encode_docs([base], [base], dim)[0]
        return [v for v in out if v is not None]

    def encode_video(self, frame_paths: list[str], dim: int = 768) -> list[float]:
        """One vector per video: mean-pooled frame content embeddings."""
        if not frame_paths:
            raise ValueError("no frames sampled")
        return mean_pool(self.encode_images(frame_paths, dim=dim))

    def encode_audio(self, wav_paths: list[str], dim: int = 768) -> list[list[float]]:
        """One vector per window. Paths route to the audio encoder by
        extension (.wav); all windows share one 16kHz rate per batch."""
        if not self._has_audio:
            raise RuntimeError("audio encoder not loaded; use get_audio_embedder()")
        vecs = self._model.encode(list(wav_paths), normalize_embeddings=True)
        import numpy as np

        return [self._finish(v, dim) for v in np.atleast_2d(vecs)]


@lru_cache(maxsize=1)
def get_embedder() -> Embedder:
    """Text-only (270M). Serves every text query and all text/doc indexing.
    This is the only pool the search path ever touches."""
    return Embedder(with_vision=False)


@lru_cache(maxsize=1)
def get_vision_embedder() -> Embedder:
    """Text+vision. Loaded lazily, only when images are indexed."""
    from .config import settings

    return Embedder(with_vision=True, vision_tokens=settings.vision_tokens)


@lru_cache(maxsize=1)
def get_audio_embedder() -> Embedder:
    """Text+audio (570M). Loaded lazily, only when audio is indexed."""
    return Embedder(with_vision=False, with_audio=True)

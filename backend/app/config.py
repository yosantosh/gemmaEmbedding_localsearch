"""App-wide settings. Single place for tunables."""

from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class Settings:
    model_id: str = "google/embeddinggemma-2"
    dims: int = 768  # native; use 256 via MRL to cut storage 3x
    normalize: bool = True
    db_path: str = "data/app.db"
    host: str = "127.0.0.1"
    port: int = 39281
    index_batch: int = 32
    index_image_batch: int = 4  # small batches bound peak RAM on weak boxes
    vision_tokens: int = 280  # per-image soft tokens (70-1120); lower = faster
    index_text_batch: int = 32  # chunks per encode call (bounds torch memory)
    index_audio_batch: int = 8  # windows per encode call
    max_text_bytes: int = 10_000_000  # larger text files are skipped, not read
    chunk_chars: int = 800
    chunk_overlap: int = 100
    text_exts: frozenset[str] = frozenset(
        {".txt", ".md", ".markdown", ".py", ".dart", ".ts", ".js", ".json"}
    )
    doc_exts: frozenset[str] = frozenset({".pdf"})
    image_exts: frozenset[str] = frozenset({".jpg", ".jpeg", ".png", ".webp"})
    audio_exts: frozenset[str] = frozenset({".mp3", ".wav", ".m4a", ".ogg"})
    video_exts: frozenset[str] = frozenset({".mp4", ".mkv", ".mov", ".webm", ".avi"})
    index_video_frames: int = 8  # evenly spaced frames pooled into one vector
    index_audio_window_sec: int = 240  # must fit 8k ctx at 25 tok/sec (~327s max)
    roots: list[str] = field(default_factory=list)


settings = Settings()

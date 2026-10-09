"""Filesystem walk + text extraction. No embeddings here (see api layer)."""

from __future__ import annotations

import os
from dataclasses import dataclass

from .config import settings


@dataclass
class FileItem:
    path: str
    kind: str  # text | pdf | image | audio | video | skip
    mtime: float
    size: int


def classify(path: str) -> str:
    ext = os.path.splitext(path)[1].lower()
    if ext in settings.text_exts:
        return "text"
    if ext in settings.doc_exts:
        return "pdf"
    if ext in settings.image_exts:
        return "image"
    if ext in settings.audio_exts:
        return "audio"
    if ext in settings.video_exts:
        return "video"
    return "skip"


def walk(roots: list[str]) -> list[FileItem]:
    items: list[FileItem] = []
    for root in roots:
        for dirpath, _, files in os.walk(root):
            for name in files:
                p = os.path.join(dirpath, name)
                kind = classify(p)
                if kind == "skip":
                    continue
                try:
                    st = os.stat(p)
                    items.append(FileItem(p, kind, st.st_mtime, st.st_size))
                except OSError:
                    continue
    return items


def chunk_text(text: str, size: int = 800, overlap: int = 100) -> list[str]:
    """Char chunking with overlap. Pure function — unit tested."""
    text = " ".join(text.split())
    if len(text) <= size:
        return [text] if text else []
    out, i = [], 0
    while i < len(text):
        out.append(text[i : i + size])
        i += size - overlap
    return out


def read_text_file(path: str) -> str:
    if path.lower().endswith(".pdf"):
        from pypdf import PdfReader

        return "\n".join((pg.extract_text() or "") for pg in PdfReader(path).pages)
    with open(path, encoding="utf-8", errors="ignore") as f:
        return f.read()


def fmt_range(start_sec: float, end_sec: float) -> str:
    """MM:SS-MM:SS label for audio window snippets."""
    return f"{fmt_dur(start_sec)}-{fmt_dur(end_sec)}"


def fmt_dur(sec: float) -> str:
    """MM:SS label (video length badges)."""
    return f"{int(sec // 60):02d}:{int(sec % 60):02d}"


def _ffmpeg_exe() -> str:
    try:
        import imageio_ffmpeg

        return imageio_ffmpeg.get_ffmpeg_exe()
    except Exception:
        return "ffmpeg"  # system fallback (dev boxes)


def media_duration(path: str, timeout: int = 60) -> float | None:
    """Duration in seconds via `ffmpeg -i` stderr parsing. None on failure."""
    import re
    import subprocess

    try:
        proc = subprocess.run(
            [_ffmpeg_exe(), "-i", path],
            capture_output=True, text=True, timeout=timeout,
        )
    except Exception:
        return None
    m = re.search(r"Duration: (\d+):(\d+):([\d.]+)", proc.stderr)
    if not m:
        return None
    h, mi, s = int(m.group(1)), int(m.group(2)), float(m.group(3))
    return h * 3600 + mi * 60 + s or None


def sample_frames(path: str, n: int, dest: str, timeout: int = 300) -> list[str]:
    """Evenly spaced JPEGs for whole-video embedding. Missing/failed → []."""
    import os
    import subprocess

    dur = media_duration(path)
    if not dur:
        return []
    out = []
    for i in range(n):
        t = dur * (i + 0.5) / n
        frame = os.path.join(dest, f"f{i:03d}.jpg")
        try:
            proc = subprocess.run(
                [_ffmpeg_exe(), "-y", "-ss", f"{t:.2f}", "-i", path,
                 "-frames:v", "1", "-vf", "scale=320:-2", "-q:v", "3", frame],
                capture_output=True, timeout=timeout,
            )
        except Exception:
            continue
        if proc.returncode == 0 and os.path.isfile(frame):
            out.append(frame)
    return out


def slice_audio(
    path: str, window_sec: int, dest: str, timeout: int = 600
) -> list[tuple[str, float, float]]:
    """Mono-16kHz WAV windows + (start, end) seconds. Unusable file → []."""
    import os
    import subprocess

    dur = media_duration(path)
    if not dur:
        return []
    out = []
    start = 0.0
    i = 0
    while start < dur:
        end = min(start + window_sec, dur)
        wav = os.path.join(dest, f"w{i:04d}.wav")
        try:
            proc = subprocess.run(
                [_ffmpeg_exe(), "-y", "-ss", f"{start:.2f}", "-t", f"{end - start:.2f}",
                 "-i", path, "-ac", "1", "-ar", "16000", "-acodec", "pcm_s16le", wav],
                capture_output=True, timeout=timeout,
            )
        except Exception:
            break
        if proc.returncode != 0 or not os.path.isfile(wav):
            break
        out.append((wav, start, end))
        start = end
        i += 1
    return out

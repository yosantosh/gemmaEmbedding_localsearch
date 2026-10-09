"""API schemas. Keep wire format stable between Flutter and backend."""

from __future__ import annotations

from pydantic import BaseModel, Field


class SearchRequest(BaseModel):
    query: str = Field(min_length=1, max_length=2000)
    top_k: int = Field(default=10, ge=1, le=50)
    kinds: list[str] = Field(default_factory=list)  # e.g. ["image","text"]
    root: str = ""


class SearchResult(BaseModel):
    path: str
    kind: str  # text | image | audio | pdf
    snippet: str = ""
    score: float  # cosine 0..1, doubles as relevancy
    mtime: float = 0.0
    vec_rank: int = -1  # 0-based meaning rank
    fts_rank: int = -1  # 0-based keyword rank; -1 when no keyword match


class SearchResponse(BaseModel):
    query: str
    results: list[SearchResult]


class IndexRequest(BaseModel):
    roots: list[str] = Field(min_length=1)
    reset: bool = False
    background: bool = False  # return immediately; poll /index/progress


class IndexProgress(BaseModel):
    running: bool
    done: int = 0
    total: int = 0
    current: str = ""
    rebuilt: bool = False
    error: str = ""  # worker failure or "cancelled by user"; "" means ok


class IndexStatus(BaseModel):
    files: int
    chunks: int
    running: bool
    roots: list[str] = Field(default_factory=list)
    rebuilt: bool = False  # true when a model/dims mismatch forced a full rebuild

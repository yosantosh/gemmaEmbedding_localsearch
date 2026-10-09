# LocalSearch — natural-language file search (EmbeddingGemma 2)

Local-first semantic search over your filesystem. Ask `photo where I wore a blue tshirt`
or `CNN notes`, get ranked results with relevancy scores. 100% on-device.

## Layout

- `backend/` — FastAPI sidecar: EmbeddingGemma 2 (`sentence-transformers`) + SQLite store + indexer.
- `app/` — Flutter chat UI (black minimalist theme, desktop-first).

## Backend

```bash
cd backend
python -m venv .venv && source .venv/bin/activate
pip install -e ".[test]"
python -m pytest tests/ -q
python -m app.main  # :39281
```

Endpoints: `GET /health`, `GET /stats`, `POST /index {roots, reset, background}`,
`POST /search {query, top_k, kinds, root}`, `GET /file?path=` (root-guarded,
powers image thumbnails). Search blends vector cosine with FTS5 keyword hits
via RRF; the shown score stays pure cosine, and each hit carries
`vec_rank` / `fts_rank` so the UI can explain the match.
`POST /index` accepts `background: true` and returns at once — poll
`GET /index/progress {running, done, total, current, rebuilt, error}` until
done. `POST /index/cancel` stops the worker after the current file;
progress then reports `error: "cancelled by user"` and partial work is kept
(commits land every 25 files, so a later run resumes).
First video frames are kept as posters under `data/posters/`, served root-guarded
at `GET /poster?path=`.

First run downloads `google/embeddinggemma-2` (~1.5GB, public — no login
needed in our test). `bfloat16` on CUDA, `float32` on CPU — never `float16`.
CPU-only install: `pip install torch torchvision --index-url
https://download.pytorch.org/whl/cpu` before the rest.

## App

```bash
cd app
flutter pub get
flutter run -d linux   # / macos / windows
```

The app talks to `http://127.0.0.1:39281`. On start it tries to bring the
backend up itself (`localsearch-backend` on PATH, then a 60s health wait);
for login-time autostart on Linux:
`tools/install_backend_service.sh --bin <path-to-binary>`.
`Up`/`Down` move through results, `Enter` opens, `Ctrl/⌘+K` focuses search.
The send button becomes Stop while searching; indexing stops from the rail.

## Packaging (desktop)

```bash
tools/run_dev.sh [linux|macos|windows]        # dev loop: backend + app
tools/package_desktop.sh --os linux           # bundle into dist/linux/
tools/build_deb.sh                            # Ubuntu .deb into dist/
```

`package_desktop.sh` builds a CPU-torch venv, freezes the backend with
PyInstaller (`backend/localsearch-backend.spec`), and runs the Flutter
release build. Model weights are never bundled — first run downloads them
(~1.5GB) into the HF cache. Sidecar auto-launch from inside the app is
still future work; `dist/<os>/RUN.txt` covers the two-process start.

The Ubuntu `.deb` (`tools/build_deb.sh`, needs `flutter`, `patchelf`,
`dpkg-deb`) ships the Flutter app only — `/usr/bin/localsearch`,
launcher, icon, man page — installable with `sudo dpkg -i
dist/localsearch_*_amd64.deb`. The backend still runs separately for now.

## Notes

Images are embedded by content (vision encoder). Video gets one mean-pooled
vector from 8 sampled frames (finds the file, not the timestamp). Audio is
sliced into ~4-min windows with one vector each, labeled `[MM:SS-MM:SS]`.
Corrupt media falls back to filename embedding. Frame/window extraction
uses a bundled ffmpeg binary (`imageio-ffmpeg`) — no system install needed. Encoders load per
modality: search runs on the text-only pool (270M, ~30s cold load on CPU),
vision loads lazily only when images are indexed. The old llama.cpp/Ollama
GGUF route stays out as default: multimodal embeddings silently fall back
to text-only there (llama.cpp#30082).
- Store is brute-force cosine over normalized vectors in one SQLite file.
  Swap for LanceDB behind the `VectorStore` interface past ~200k vectors.

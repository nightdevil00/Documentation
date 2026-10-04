# Offline wallpaper classification with llama.cpp

Sort a wallpaper folder into category subfolders using a **local** vision model.
No API keys, no per-image cost, no image ever leaves the machine.

Built and verified on **Omarchy 4.0** (Arch, Hyprland), llama.cpp `b11344`,
`Qwen2.5-VL-3B-Instruct-Q4_K_M`, GTX 1650 Ti (4 GB).

---

## Contents

1. [What it does](#1-what-it-does)
2. [Requirements](#2-requirements)
3. [Install llama.cpp](#3-install-llamacpp)
4. [Get the model](#4-get-the-model)
5. [Install the script](#5-install-the-script)
6. [Run it](#6-run-it)
7. [Options](#7-options)
8. [Running the server yourself](#8-running-the-server-yourself)
9. [Troubleshooting](#9-troubleshooting)
10. [Four bugs worth knowing about](#10-four-bugs-worth-knowing-about)
11. [Notes and limits](#11-notes-and-limits)

---

## 1. What it does

Point it at a folder of images. For each one it asks a vision model to pick a
single category from a fixed list, then files the image under that category.

```
~/Pictures/Wallpapers/          ~/Pictures/Wallpapers-sorted/
  100.png                         abstract-geometry/
  1188.gif                        abstract-gradient/
  169.gif                         anime-illustration/
  1700.png                        architecture-urban/
  ...                             minimal-typography/
                                  nature-bright/
                                  nature-dark/
                                  object-minimal/
                                  other/
                                  space/
```

Design points worth knowing:

- **Standard library only.** No `pip install`, no venv. Python 3.11+ and ImageMagick.
- **Grammar-constrained output.** A GBNF grammar pins the reply to one of the ten
  category names, so the model cannot invent a label.
- **Cached and resumable.** Every result is appended to
  `~/.cache/wallpaper-sort/classified.tsv` and flushed immediately. Interrupt it,
  reboot, whatever — rerunning picks up where it left off.
- **Report-only by default.** Nothing moves until you pass `--apply`.
- **One image at a time**, sequential. No VRAM spikes, no OOM on small GPUs.

---

## 2. Requirements

| Need | Why | Check |
| --- | --- | --- |
| Python 3.11+ | runs the script | `python3 --version` |
| ImageMagick 7 | resizes + converts frames to JPEG | `magick -version` |
| llama.cpp with `llama-server` + `libmtmd` | inference **and** vision | see §3 |
| ~2.6 GB disk | model cache | — |
| ~4 GB RAM, a GPU is strongly recommended | speed | — |

On Omarchy / Arch:

```bash
omarchy pkg add imagemagick python
```

ImageMagick 7 is required — the script calls `magick` (not the legacy `convert`).
Arch's `imagemagick` package is 7.x, so `omarchy pkg add imagemagick` is correct.

A GPU is not required, but see [measured performance](#measured-performance) —
CPU-only is roughly 3x slower per image at reduced image tokens.

---

## 3. Install llama.cpp

You need a build that includes **both** `llama-server` **and** multimodal
support (`libmtmd`). A text-only build will start, accept your image, and fail.

### Option A — Arch package (easiest, CPU-only)

```bash
omarchy pkg add llama-cpp
```

`extra/llama-cpp` ships `llama-server`, `libmtmd.so` and even systemd units.
It is **CPU-only**, which is fine for a test run but slow for thousands of
images.

Binary lands at `/usr/bin/llama-server`. Either edit `LLAMA_BIN` in the script
(see §5) or skip that step by starting the server yourself (§8) — the script
reuses an already-running server on the port.

### Option B — prebuilt GPU binary (recommended)

**The stable tag ships no binaries.** `v0.5.0` contains only `nightly-tag.txt`.
Prebuilt Linux binaries live on the **rolling nightly tags** (`b11385`,
`b11384`, …). Find the newest one:

```bash
curl -s https://api.github.com/repos/ggml-org/llama.cpp/releases \
  | grep -o '"tag_name": *"b[0-9]*"' | head -1
```

Then pick the asset for your GPU from that release:

| Asset suffix | Use for |
| --- | --- |
| `cudart-llama-<tag>-bin-ubuntu-cuda-13.4-x64.tar.gz` | NVIDIA — **bundles** the CUDA runtime, no toolkit needed |
| `llama-<tag>-bin-ubuntu-cuda-13.4-x64.tar.gz` | NVIDIA, if you already have CUDA |
| `llama-<tag>-bin-ubuntu-rocm-10.0-x64.tar.gz` | AMD |
| `llama-<tag>-bin-ubuntu-vulkan-x64.tar.gz` | any GPU via Vulkan — good on hybrid laptops |
| `llama-<tag>-bin-ubuntu-sycl-fp16-x64.tar.gz` | Intel Arc |
| `llama-<tag>-bin-ubuntu-x64.tar.gz` | CPU only, 17 MB |

Prefer the `cudart-` build on NVIDIA: it ships `libcudart.so`/`libcublas.so`
inside the tarball, so you need **no** CUDA toolkit on the host. (Confirmed
working on a machine with no `nvcc` at all.)

```bash
TAG=b11385   # <- the tag you found above
mkdir -p ~/llama.cpp/build/bin
tar -xf ~/Downloads/llama-$TAG-bin-ubuntu-vulkan-x64.tar.gz \
      -C ~/llama.cpp/build/bin --strip-components=1
```

**`--strip-components=1` is required.** The tarball's top-level directory is
`llama-<tag>/`, so without the strip you get `~/llama.cpp/llama-<tag>/llama-server`
and the script will not find it.

Verify:

```bash
~/llama.cpp/build/bin/llama-server --version
# version: 0.5.0-dev (build 11385, commit bf9a0ccce)
```

If it prints a version, you're good.

### Option C — AUR

```bash
yay -S llama.cpp-cuda-git     # NVIDIA
yay -S llama.cpp-hip-git      # AMD
yay -S llama.cpp-git          # CPU
```

These install to `/usr/bin/llama-server`, so point `LLAMA_BIN` at that path
(§5) or start the server yourself (§8).

### Sanity check that vision is compiled in

```bash
~/llama.cpp/build/bin/llama-server --help 2>&1 | grep -E 'image-max-tokens|mmproj'
```

You want to see `--image-max-tokens N` and `--mmproj-auto`. If those are
missing, you have a text-only build and the script cannot work.

---

## 4. Get the model

**You don't have to do anything.** `llama-server -hf <repo>` downloads the
model and the vision projector on first run via its own built-in downloader —
no `huggingface-cli`, no `hf` package.

```bash
~/llama.cpp/build/bin/llama-server \
  -hf ggml-org/Qwen2.5-VL-3B-Instruct-GGUF \
  --port 8080 -c 2048 --jinja -ngl 99 --parallel 1 \
  --image-min-tokens 128 --image-max-tokens 256
```

That single command is also exactly what the script runs. First start takes a
few minutes and shows download progress; later starts load from cache in ~3 s.

Two files land in the HF cache (~2.6 GB total):

```
~/.cache/huggingface/hub/models--ggml-org--Qwen2.5-VL-3B-Instruct-GGUF/
  Qwen2.5-VL-3B-Instruct-Q4_K_M.gguf     1.8 GiB   <- the model
  mmproj-Qwen2.5-VL-3B-Instruct-Q8_0.gguf  805 MiB  <- the vision projector
```

The **mmproj is not optional.** Without it the server has no eyes. If you see
`Failed to load image or audio file` on every request, check it downloaded.

Picking a different quant — append it to the repo name:

```bash
-hf ggml-org/Qwen2.5-VL-3B-Instruct-GGUF:Q8_0     # bigger, more accurate
-hf ggml-org/Qwen2.5-VL-3B-Instruct-GGUF:Q4_K_M   # the default
```

Gated repos need a token: export `HF_TOKEN=hf_...`.

### Measured performance

Per image, 768 px longest edge, `temperature 0`, ~5 output tokens:

| Backend | Image tokens | Per image | Rate | 4 000 images |
| --- | --- | --- | --- | --- |
| GTX 1650 Ti (4 GB), CUDA | 256 | 3.7 s | 0.27/s | ~4 h |
| CPU only, 6 cores | 64 | 10.3 s | 0.10/s | ~11 h |

Both produced the same correct label. Cost is dominated by the **vision
encoder** (the prompt), not by the 5 generated tokens.

---

## 5. Install the script

Save it as `~/.local/bin/wallpaper-sort` and make it executable:

```bash
mkdir -p ~/.local/bin
chmod +x ~/.local/bin/wallpaper-sort
```

It is Python stdlib only, so there is nothing to install.

One line to check or change:

```python
LLAMA_BIN = str(Path.home() / "llama.cpp/build/bin/llama-server")
```

That matches Option B's install layout. If you used Option A or C, either point
it at `/usr/bin/llama-server`, or symlink:

```bash
mkdir -p ~/llama.cpp/build/bin
ln -sf /usr/bin/llama-server ~/llama.cpp/build/bin/llama-server
```

### The script

```python
#!/usr/bin/env python3
"""Sort a wallpaper folder into category subfolders using a local llama.cpp vision model."""

import argparse
import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

CATEGORIES = [
    "nature-dark",
    "nature-bright",
    "space",
    "anime-illustration",
    "minimal-typography",
    "abstract-gradient",
    "abstract-geometry",
    "architecture-urban",
    "object-minimal",
    "other",
]

GLOSSARY = """
nature-dark: dark, moody outdoor scenes - night forests, dark water, cliffs, storms, rain, silhouette landscapes
nature-bright: sunlit nature - flowers, ferns, macro plants, bright countryside, pastel scenery, daylight landscapes
space: starfields, night skies, planets, galaxies, nebulae, the cosmos
anime-illustration: hand-drawn anime, manga or Studio Ghibli style artwork, illustrated scenes and characters
minimal-typography: mostly empty flat background with words, letters, quotes or monospace text on it
abstract-gradient: plain smooth colour gradients or simple solid colour fields
abstract-geometry: 3D shapes, polygons, hexagon patterns, fluid marble swirls, neon curved lines, digital patterns
architecture-urban: buildings, houses, cities, streets, neon cyberpunk skylines, interior architecture
object-minimal: one small isolated object on a plain dark or empty background
other: anything that does not fit the categories above
"""

PROMPT = (
    "Classify this wallpaper image into exactly one category.\n"
    "Categories:\n" + GLOSSARY + "\n"
    "Answer with the category name only, in lowercase, no punctuation, no explanation.\n"
    "Category:"
)

GRAMMAR = "root ::= " + " | ".join(f'"{c}"' for c in CATEGORIES)

LLAMA_BIN = str(Path.home() / "llama.cpp/build/bin/llama-server")
DEFAULT_MODEL = "ggml-org/Qwen2.5-VL-3B-Instruct-GGUF"
HOST = "127.0.0.1"
PORT = 8080
IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".gif", ".jxl", ".avif"}


def health(port):
    try:
        with urllib.request.urlopen(f"http://{HOST}:{port}/health", timeout=2):
            return True
    except Exception:
        return False


def encode_image(path, max_dim):
    """Downscale and re-encode so the base64 payload stays small and vision stays fast."""
    if not max_dim:
        return base64.b64encode(Path(path).read_bytes()).decode()
    # "[0]" keeps only the first frame: an animated gif/webp would otherwise make magick
    # write one file per frame (out-0.jpg, out-1.jpg, ...) and leave our target empty.
    with tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as tmp:
        tmp_path = tmp.name
    proc = subprocess.run(
        ["magick", f"{path}[0]", "-auto-orient", "-resize", f"{max_dim}x{max_dim}>",
         "-quality", "85", tmp_path],
        capture_output=True,
    )
    blob = Path(tmp_path).read_bytes() if proc.returncode == 0 else b""
    Path(tmp_path).unlink(missing_ok=True)
    if proc.returncode != 0:
        raise Unreadable(proc.stderr.decode(errors="replace").strip().splitlines()[-1][:120])
    if not blob:
        raise Unreadable("magick produced an empty frame")
    return base64.b64encode(blob).decode()


class Unreadable(Exception):
    pass


def classify(data_uri, port, timeout):
    body = {
        "messages": [
            {"role": "user", "content": [
                {"type": "text", "text": PROMPT},
                {"type": "image_url",
                 "image_url": {"url": f"data:image/jpeg;base64,{data_uri}"}},
            ]},
        ],
        "temperature": 0.0,
        "max_tokens": 16,
        "cache_prompt": True,
        "grammar": GRAMMAR,
    }
    req = urllib.request.Request(
        f"http://{HOST}:{port}/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        out = json.load(resp)
    text = out["choices"][0]["message"]["content"].strip().lower()
    text = "".join(c for c in text if c.isalnum() or c in "-_")
    if text in CATEGORIES:
        return text, ""
    for cat in CATEGORIES:
        if cat in text:
            return cat, "fuzzy"
    return "other", "invalid:" + text[:24]


def load_cache(path):
    cache = {}
    if path.exists():
        for line in path.read_text(errors="replace").splitlines():
            parts = line.rstrip("\n").split("\t")
            if len(parts) == 3:
                cache[parts[0]] = (parts[1], parts[2])
    return cache


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("folder", nargs="?", default="~/Pictures/Wallpapers")
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--port", type=int, default=PORT)
    ap.add_argument("--dest", default=None, help="default: <folder>-sorted")
    ap.add_argument("--max-dim", type=int, default=768, help="0 disables downscaling")
    ap.add_argument("--image-tokens", type=int, default=256,
                    help="vision tokens per image; lower = faster, 256 is a good balance")
    ap.add_argument("--timeout", type=int, default=300)
    ap.add_argument("--limit", type=int, default=0, help="classify only N new files")
    ap.add_argument("--apply", action="store_true", help="actually move files (default: report only)")
    ap.add_argument("--in-place", "--dry-run-apply", dest="in_place", action="store_true",
                    help="MOVES files into category subfolders of the source folder "
                         "(same destructive move as --apply, just a different destination)")
    args = ap.parse_args()

    folder = Path(args.folder).expanduser().resolve()
    if not folder.is_dir():
        sys.exit(f"not a directory: {folder}")
    if args.in_place:
        dest = folder
    else:
        dest = Path(args.dest).expanduser().resolve() if args.dest \
            else folder.with_name(folder.name + "-sorted")

    files = sorted(p for p in folder.rglob("*")
                   if p.is_file() and p.suffix.lower() in IMAGE_EXTS
                   and dest not in p.parents)
    cache_path = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) \
        / "wallpaper-sort" / "classified.tsv"
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    cache = load_cache(cache_path)
    todo = [p for p in files if str(p) not in cache]
    if args.limit:
        todo = todo[:args.limit]

    print(f"folder : {folder}")
    print(f"images : {len(files)} ({len(cache)} already classified, {len(todo)} to do)")
    print(f"dest   : {dest}" + ("" if args.apply else "   [REPORT ONLY - pass --apply to move]"))

    server = None
    if todo and not health(args.port):
        if not Path(LLAMA_BIN).exists():
            sys.exit(f"no server running on :{args.port} and {LLAMA_BIN} not found")
        print(f"starting llama-server ({args.model}) ...")
        server = subprocess.Popen(
            [LLAMA_BIN, "-hf", args.model, "--port", str(args.port),
             "-c", "2048", "--jinja", "-ngl", "99", "--parallel", "1",
             "--image-min-tokens", str(min(128, args.image_tokens)),
             "--image-max-tokens", str(args.image_tokens)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        for _ in range(300):
            if health(args.port):
                break
            if server.poll() is not None:
                sys.exit("llama-server exited during startup - run it by hand to see why:\n"
                         f"  {LLAMA_BIN} -hf {args.model} -c 2048 --jinja -ngl 99")
            time.sleep(1)
        else:
            server.terminate()
            sys.exit("llama-server did not become healthy in 300s")
        print("server ready")

    t0 = time.time()
    counts, unreadable, done, failures = {}, [], 0, 0
    try:
        with cache_path.open("a") as log:
            for path in todo:
                try:
                    cat, note = classify(encode_image(path, args.max_dim),
                                         args.port, args.timeout)
                except Unreadable as exc:
                    unreadable.append((path.name, str(exc)))
                    continue
                except urllib.error.HTTPError as exc:
                    # 4xx is this payload's fault, not the server's: skip the file.
                    why = exc.read().decode(errors="replace").strip().replace("\n", " ")[:140]
                    if exc.code < 500:
                        unreadable.append((path.name, f"HTTP {exc.code}: {why}"))
                    else:
                        failures += 1
                        print(f"  !! {path.name}: HTTP {exc.code}: {why}")
                        if failures >= 5:
                            sys.exit("\nserver stopped responding - bailing out. "
                                     "progress is cached, rerun to continue")
                    continue
                except (urllib.error.URLError, OSError) as exc:
                    failures += 1
                    print(f"  !! {path.name}: {exc}")
                    if failures >= 5:
                        sys.exit("\nserver stopped responding - bailing out. "
                                 "progress is cached, rerun to continue")
                    continue
                log.write(f"{path}\t{cat}\t{note}\n")
                log.flush()
                cache[str(path)] = (cat, note)
                counts[cat] = counts.get(cat, 0) + 1
                if note.startswith("invalid"):
                    unreadable.append((path.name, "unparseable answer: " + note))
                done += 1
                rate = done / max(time.time() - t0, 1e-9)
                left = (len(todo) - done) / rate if rate else 0
                extra = f" [{note}]" if note else ""
                print(f"[{done}/{len(todo)}] {rate:.2f}/s eta {left/60:.0f}m  "
                      f"{cat:<20} {path.name}{extra}")
    except KeyboardInterrupt:
        print("\ninterrupted - progress is cached, rerun to continue")
    finally:
        if server is not None:
            # terminate() only *asks*: llama-server can still be holding the model and
            # ~3GB of VRAM when we return, and an orphan keeps :8080 busy so the next
            # run silently reuses it. Wait it out, then escalate.
            server.terminate()
            try:
                server.wait(timeout=20)
            except subprocess.TimeoutExpired:
                print("  llama-server ignored SIGTERM, sending SIGKILL")
                server.kill()
                try:
                    server.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    print(f"  WARNING: pid {server.pid} is still alive - "
                          f"run: kill -9 {server.pid}")
            print("stopped llama-server")

    print("\nsummary")
    for cat, n in sorted(counts.items(), key=lambda kv: -kv[1]):
        print(f"  {cat:<20} {n}")
    for name, why in unreadable[:10]:
        print(f"  skipped {name}: {why}")
    if len(unreadable) > 10:
        print(f"  ... and {len(unreadable) - 10} more skipped")

    if args.apply:
        moved = 0
        for src, (cat, _n) in cache.items():
            src = Path(src)
            if not src.exists():
                continue
            target_dir = dest / cat
            target_dir.mkdir(parents=True, exist_ok=True)
            target = target_dir / src.name
            n = 1
            while target.exists() and target.read_bytes() != src.read_bytes():
                target = target_dir / f"{src.stem}-{n}{src.suffix}"
                n += 1
            shutil.move(str(src), str(target))
            moved += 1
        print(f"\nmoved {moved} files into {dest}/<category>/")
    else:
        print(f"\nnot moved anything. rerun with --apply to file them under {dest}/")


if __name__ == "__main__":
    main()
```

### Customising the categories

Edit `CATEGORIES` and `GLOSSARY`. They must stay in sync — `CATEGORIES` builds
the grammar, `GLOSSARY` builds the prompt. Order does not matter, but the
glossary lines are what actually steer the model; vague descriptions give vague
labels. Reuse your own vocabulary (`anime-illustration` vs `anime` vs `waifu`
changes the results more than the model does).

After changing categories, previously cached results still apply. Clear the
cache to re-classify:

```bash
rm ~/.cache/wallpaper-sort/classified.tsv
```

---

## 6. Run it

Always start with a report-only run. It classifies, prints, and moves nothing.

```bash
wallpaper-sort ~/Pictures/Wallpapers
```

```
folder : /home/you/Pictures/Wallpapers
images : 4469 (0 already classified, 4469 to do)
dest   : /home/you/Pictures/Wallpapers-sorted   [REPORT ONLY - pass --apply to move]
starting llama-server (ggml-org/Qwen2.5-VL-3B-Instruct-GGUF) ...
server ready
[1/4469] 0.27/s eta 269m  object-minimal        100.png
[2/4469] 0.28/s eta 265m  nature-dark          1000.png
...
```

First run downloads the model, so allow a few extra minutes. Then move:

```bash
wallpaper-sort ~/Pictures/Wallpapers --apply
```

`--apply` moves every **cached** result, not just this run's — so if you
interrupted a run, the partial results still get filed.

### Suggested workflow

```bash
# 1. smoke test on 20 images, no moves
wallpaper-sort ~/Pictures/Wallpapers --limit 20

# 2. eyeball the labels, tweak CATEGORIES/GLOSSARY if needed
#    (then: rm ~/.cache/wallpaper-sort/classified.tsv)

# 3. full classify, still no moves - safe to Ctrl-C, it resumes
wallpaper-sort ~/Pictures/Wallpapers

# 4. satisfied with the summary? file everything
wallpaper-sort ~/Pictures/Wallpapers --apply
```

Step 3 before 4 matters: `--apply` replays your whole cache, so a bad
vocabulary means re-filing everything by hand.

### Running it in the background

```bash
wallpaper-sort ~/Pictures/Wallpapers > ~/wallpaper-sort.log 2>&1 &
tail -f ~/wallpaper-sort.log
```

On a laptop, keep it plugged in — it is GPU-bound and will drain a battery in a
few hours. Suspend is safe: results are flushed per image.

---

## 7. Options

```
wallpaper-sort [-h] [--model MODEL] [--port PORT] [--dest DEST]
               [--max-dim MAX_DIM] [--image-tokens IMAGE_TOKENS]
               [--timeout TIMEOUT] [--limit LIMIT] [--apply] [--in-place]
               [folder]
```

| Flag | Default | Notes |
| --- | --- | --- |
| `folder` | `~/Pictures/Wallpapers` | scanned with `rglob`, so subfolders count |
| `--model` | `ggml-org/Qwen2.5-VL-3B-Instruct-GGUF` | any GGUF vision model; `:QUANT` suffix allowed |
| `--port` | `8080` | must match a server you started yourself |
| `--dest` | `<folder>-sorted` | ignored with `--in-place` |
| `--max-dim` | `768` | longest edge in px; `0` disables downscaling |
| `--image-tokens` | `256` | vision tokens per image. **The main speed knob** |
| `--timeout` | `300` | seconds per request |
| `--limit` | `0` (all) | classify only N new files |
| `--apply` | off | **actually move files** |
| `--in-place` | off | move into category subfolders **of the source folder** |

### `--in-place` is not a dry run

Despite the old `--dry-run-apply` alias it still keeps for compatibility, this
flag **moves files**. It only changes the destination. The name is a warning, not
a promise — `--apply --in-place` files your walls in place.

### Tuning

```bash
# faster, rougher: half the vision tokens, ~2x quicker
wallpaper-sort --image-tokens 128

# more accurate: llama.cpp itself suggests 1024+ for Qwen-VL (see §9)
wallpaper-sort --image-tokens 1024

# fewer vision tokens, smaller upload
wallpaper-sort --image-tokens 256 --max-dim 512
```

`--max-dim 0` sends the original file bytes, which for a 4K PNG means a huge
base64 payload and a much slower vision pass. Only useful for debugging.

### The cache

```
~/.cache/wallpaper-sort/classified.tsv
```

Tab-separated: `absolute-path`, `category`, `note`. Append-only and flushed per
line, so it survives a hard kill.

```bash
wc -l ~/.cache/wallpaper-sort/classified.tsv     # how many are done
cut -f2 ~/.cache/wallpaper-sort/classified.tsv | sort | uniq -c | sort -rn   # distribution
grep -c 'invalid' ~/.cache/wallpaper-sort/classified.tsv                     # unparseable answers
```

The third field is empty on a clean grammar hit, `fuzzy` if the reply needed
substring recovery, and `invalid:...` if nothing matched (it is filed as
`other`).

---

## 8. Running the server yourself

The script starts a server only if nothing healthy is on `--port`. So a
long-lived server works, and you avoid paying the ~3 s load on every run.

```bash
~/llama.cpp/build/bin/llama-server \
  -hf ggml-org/Qwen2.5-VL-3B-Instruct-GGUF \
  --port 8080 -c 2048 --jinja -ngl 99 --parallel 1 \
  --image-min-tokens 128 --image-max-tokens 256
```

Or as a user service — `extra/llama-cpp` ships `llama-server.service`:

```bash
systemctl --user edit llama-server   # set ExecStart to your model + flags
systemctl --user enable --now llama-server
```

Keep these in mind when you tune them yourself:

| Flag | Why |
| --- | --- |
| `--jinja` | required for Qwen2.5-VL's chat template |
| `--parallel 1` | one slot. More slots = more VRAM, no gain for a sequential client |
| `-c 2048` | ample for a ~300-token prompt. Raise only if you use a long glossary |
| `--image-max-tokens N` | must be ≥ `--image-min-tokens`. Dominates speed and RAM |
| `-ngl 99` | "offload everything". See the warning in §9 — it can overshoot small GPUs |

---

## 9. Troubleshooting

Start here:

```bash
curl -s http://127.0.0.1:8080/health          # {"status":"ok"} or connection refused
pgrep -af llama-server                        # is anything running?
nvidia-smi --query-compute-apps=pid,used_memory --format=csv   # is it on the GPU?
tail -20 /path/to/your/server.log             # what did it say at startup?
```

### `no server running on :8080 and <path> not found`

`LLAMA_BIN` points somewhere that does not exist. Check it:

```bash
ls -l ~/llama.cpp/build/bin/llama-server
grep -n 'LLAMA_BIN' ~/.local/bin/wallpaper-sort
```

Remember `--strip-components=1` when extracting (§3), and that AUR/Arch builds
live at `/usr/bin/llama-server`.

### `llama-server exited during startup`

The script hides the server's output, so it cannot tell you why. Run the exact
command by hand — the message prints it for you:

```bash
~/llama.cpp/build/bin/llama-server -hf ggml-org/Qwen2.5-VL-3B-Instruct-GGUF -c 2048 --jinja -ngl 99
```

### Every request fails with `HTTP 400` / `Failed to load image or audio file`

The server could not decode the image you sent. Reproduce and get the real
message:

```bash
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":[
      {"type":"text","text":"describe this"},
      {"type":"image_url","image_url":{"url":"data:image/jpeg;base64,<PASTE_BASE64>"}}]}],
      "max_tokens":16}'
```

An empty `<PASTE_BASE64>` gives exactly this error — that is the fingerprint of
a **zero-byte payload**. In practice that means `encode_image` produced nothing;
see §10 bug 1.

Other causes: a text-only llama.cpp with no `mmproj` (§3 sanity check), or a
truncated image — check `magick identify <file>` reports a real geometry.

### `server stopped responding - bailing out`

Five consecutive transport failures or `5xx`. Progress is cached; rerun to
continue. To see the real error, start the server yourself with a log (§8).

### Stuck at `starting llama-server`

Killed by the 300 s startup timeout. Almost always the first-run model download,
which prints nothing because the script sends the server's output to
`/dev/null`. Wait for the model to finish downloading once:

```bash
du -sh ~/.cache/huggingface/hub/models--ggml-org--Qwen2.5-VL-3B-Instruct-GGUF
# ~2.6G when complete
```

### Warning: `failed to fit params to free device memory: n_gpu_layers already set by user to 99, abort`

Expected on a small GPU. `-ngl 99` asks for every layer on the GPU; on a 4 GB
card the model plus projector plus vision encoder does not quite fit, so
llama.cpp gives up on auto-fitting and spills some layers to system RAM. It
**still works** — it is a warning, not an error — but it costs speed.

Let llama.cpp choose instead of forcing a number:

```bash
# drop -ngl 99 entirely -> auto-fit
```

Or set it lower. On the reference machine (4 GB) it ran at 3.7 s/image while
using 2 930 MiB of VRAM, which is fine.

### Warning: `Qwen-VL models require at minimum 1024 image tokens`

Also expected. llama.cpp recommends ≥1024 image tokens for Qwen-VL accuracy; the
script defaults to 256 for speed. If you see too many misclassifications:

```bash
wallpaper-sort --image-tokens 1024
```

Slower, but more accurate — especially for text-in-image and small subjects.

### `Warning: no API key is set and CORS allows all origins`

Harmless locally. The server binds `127.0.0.1` only. Add `--api-key` if you
ever expose it.

### `Notice: server default port will be changed to :9931 in a future release`

Upstream is moving the default port. The script passes `--port` explicitly, so
it is unaffected — but if you hardcode 8080 anywhere else, keep an eye out.

### A stale server is holding the port

If a previous run was killed hard, the server may survive, still holding ~3 GB
of VRAM and `:8080`. The next run reuses it silently (by design), so it never
gets cleaned up:

```bash
pgrep -af llama-server
nvidia-smi --query-compute-apps=pid,used_memory --format=csv
kill -9 <pid>
```

The version of the script above waits for a clean exit and escalates to
`SIGKILL` itself, so this should not recur.

### Rate is much slower than expected

Check `/tmp` first — a leak there means a very old version:

```bash
ls /tmp/tmp*.jpg 2>/dev/null | wc -l
```

Then lower the cost:

```bash
wallpaper-sort --image-tokens 128 --max-dim 512
```

Confirm the GPU is actually being used — if `nvidia-smi` shows no compute apps
you fell back to CPU and can expect ~3x the time.

### Results look wrong

They are still cached. Edit `CATEGORIES`/`GLOSSARY`, then:

```bash
rm ~/.cache/wallpaper-sort/classified.tsv
wallpaper-sort ~/Pictures/Wallpapers          # report only
```

### Want to start over

```bash
rm ~/.cache/wallpaper-sort/classified.tsv     # forget all classifications
```

Nothing has moved unless you passed `--apply`, so the source folder is intact.

---

## 10. Four bugs worth knowing about

These all bit during development. They are fixed above, but they are the kind
of thing you will reinvent if you write your own version, so they are written
down.

### 1. ImageMagick and animated GIFs → zero-byte payload → HTTP 400

`magick` given a multi-frame input and a single output path writes **one file
per frame**, numbered:

```
out-0.jpg  out-1.jpg  ...  out-161.jpg
```

It never writes `out.jpg`. So if you pre-create the output with
`tempfile.NamedTemporaryFile` (which creates a 0-byte file) and then read it
back, you get **0 bytes** — and send `data:image/jpeg;base64,` with nothing
after it. The server correctly answers:

```json
{"error":{"code":400,"message":"Failed to load image or audio file","type":"invalid_request_error"}}
```

`magick` exits **0**, so a return-code check catches nothing.

Two fixes, both needed:

```python
["magick", f"{path}[0]", ...]     # take frame 0 explicitly
blob = Path(tmp_path).read_bytes()
if not blob:
    raise Unreadable("magick produced an empty frame")   # assert, don't trust
```

Your wallpaper folder will have animated GIFs. On the reference folder, all 149
had between 20 and 162 frames and **every single one** hit this.

### 2. A `4xx` is not a dead server

`urllib.error.HTTPError` subclasses `urllib.error.URLError`, so a handler
catching `URLError` cannot tell "the image was rejected" from "the server
crashed". With a threshold of five failures, one bad file type deadlocks the
whole run:

- files are processed in sorted order,
- the first five GIFs always fail,
- five failures → exit,
- every rerun hits the same five GIFs → **zero progress, forever**.

The fix is to catch `HTTPError` *before* `URLError` and branch on the status:

```python
except urllib.error.HTTPError as exc:
    if exc.code < 500:
        unreadable.append(...)   # this payload is bad, skip it
    else:
        failures += 1            # the server is unwell
```

**Lesson:** order your `except` clauses most-specific-first, and never treat a
client error as a server outage. If you see the same files failing on every
run and no progress, you have this bug.

### 3. `Popen.terminate()` is a request, not a guarantee

`terminate()` sends `SIGTERM` and returns immediately. If the script then exits,
the server can be left running — still holding the model, ~3 GB of VRAM, and
`:8080`. The next run's health check *reuses* it, so it is never cleaned up.
This is invisible in the output: the script cheerfully prints
`stopped llama-server`.

Wait for it, then escalate:

```python
server.terminate()
try:
    server.wait(timeout=20)
except subprocess.TimeoutExpired:
    server.kill()
    server.wait(timeout=10)
```

Only mention `llama-server` cleanup when `server is not None` — i.e. when *you*
started it. If the script adopted an existing server, it must not kill it.

### 4. Temp files leak on the happy path

`NamedTemporaryFile(delete=False)` needs an explicit `unlink()`. Without one,
every classified image leaves a ~50 KB JPEG in `/tmp` forever. Over a 4 000-image
run that is thousands of files. Unlink on **every** path, including the error
path — read the bytes first, then delete, then validate:

```python
blob = Path(tmp_path).read_bytes() if proc.returncode == 0 else b""
Path(tmp_path).unlink(missing_ok=True)
```

Check for the leak any time with `ls /tmp/tmp*.jpg | wc -l`.

---

## 11. Notes and limits

- **Animated GIFs are classified by their first frame only.** With `[0]` they are
  treated as ordinary stills. If a GIF's meaning is in its motion, this will
  misfile it.
- **HEIC/AVIF** is in `IMAGE_EXTS`, but only works if your `magick` has the
  delegate. Files that fail to decode are reported as `skipped`, not fatal.
- **`--apply` is a move, not a copy.** Source files are gone from the original
  folder. Use `--in-place` if you want them grouped where they already live.
- **Name collisions** are resolved by content comparison, then `-1`, `-2`
  suffixes. Different files with the same name are both kept.
- **The cache is keyed by absolute path.** Moving or renaming your wallpaper
  folder makes every entry a miss and re-classifies from scratch.
- **`--apply` walks the entire cache**, not just the current run. Deleting the
  cache after files have been moved is fine — missing sources are skipped.
- **Quality is model-bound, not code-bound.** At 256 image tokens on a 3B model,
  expect the occasional odd label. Bump `--image-tokens` before you start
  rewriting the glossary.
- **`temperature 0.0` + grammar** means the same image always gets the same
  label. Good for reproducibility; it also means the model cannot be nudged out
  of a bad habit by luck.

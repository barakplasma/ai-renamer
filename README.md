# ai-renamer

A native Bend CLI that renames files from their contents using Ollama, LM Studio, OpenAI, or an OpenAI-compatible local endpoint. It handles images, videos, documents, and text or source files. It includes the progress bar, ETA, and recursive traversal from [upstream PR #27](https://github.com/ozgrozer/ai-renamer/pull/27).

## Getting started

### 1. Install the binary

Download the archive for your machine from [Releases](https://github.com/barakplasma/ai-renamer/releases). Until a release is published, sign in to GitHub and download the matching artifact from the latest successful [CI run on `bend-rewrite`](https://github.com/barakplasma/ai-renamer/actions/workflows/ci-release.yml?query=branch%3Abend-rewrite). Unzip the GitHub artifact first to get the `.tar.gz`. Use `uname -m` if you need to check your architecture.

| Machine | Archive |
| --- | --- |
| macOS, Apple silicon (`arm64`) | `ai-renamer-darwin-arm64.tar.gz` |
| macOS, Intel (`x86_64`) | `ai-renamer-darwin-amd64.tar.gz` |
| Linux, Intel or AMD (`x86_64`) | `ai-renamer-linux-amd64.tar.gz` |
| Linux, ARM (`aarch64`) | `ai-renamer-linux-arm64.tar.gz` |

From the download directory, replace `ARCHIVE.tar.gz` with your archive's filename:

```sh
tar -xzf ARCHIVE.tar.gz
mkdir -p "$HOME/.local/bin"
install -m 755 ai-renamer "$HOME/.local/bin/ai-renamer"
export PATH="$HOME/.local/bin:$PATH"
ai-renamer --version
```

The binary needs no Bend compiler. Linux builds target Ubuntu 24.04 and use the system libcurl and OpenSSL libraries. If those are missing on Ubuntu 24.04, install them with `sudo apt install libcurl4t64 libssl3t64`. Video requires FFmpeg and FFprobe. Local PDF extraction requires Poppler's `pdftotext`.

### 2. Choose a model you can run locally

A model server can run on the same machine or at an address you can reach. Use `--provider=local --base-url=URL` with any server that exposes OpenAI Chat Completions. The CLI queries `/v1/models` when you leave out `--model`. If the server has only a chat endpoint, pass its model ID explicitly. The local provider stores its endpoint, model, and API key separately from the other providers. Changing its endpoint clears the previously saved local model and key unless you explicitly supply replacements.

The examples below use disposable text files. Images and video frames also require a model server that accepts image inputs.

#### Mozilla llamafile

Download Mozilla's [single-file Llama 3.2 1B model](https://huggingface.co/mozilla-ai/Llama-3.2-1B-Instruct-llamafile/tree/main). On Linux or macOS, launch the bundled runtime and model in one terminal:

```sh
curl -fLO https://huggingface.co/mozilla-ai/Llama-3.2-1B-Instruct-llamafile/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.llamafile
chmod +x Llama-3.2-1B-Instruct-Q4_K_M.llamafile
./Llama-3.2-1B-Instruct-Q4_K_M.llamafile --server --host 127.0.0.1 --port 8080
```

In another terminal, run:

```sh
sample_dir=$(mktemp -d)
printf '%s\n' 'Quarterly sales report for the home appliances division.' > "$sample_dir/sample.txt"
ai-renamer "$sample_dir/sample.txt" --provider=local --base-url=http://127.0.0.1:8080
```

This example model accepts text. On Windows, Mozilla supports running compatible llamafiles as `.exe` files. Use the Windows server from an ai-renamer session in Linux or WSL that can reach its address. See the [llamafile quick-start](https://github.com/mozilla-ai/llamafile/blob/main/docs/quickstart.md).

#### Apple Foundation Models on macOS 27

On a Mac with Apple Intelligence enabled, run `fm serve` in a separate terminal. If prompted, review Apple's terms with `sudo fm license`. The default local endpoint is:

```sh
ai-renamer /path/to/sample.txt --provider=local --base-url=http://127.0.0.1:1976 --model=system
```

Apple's `fm` ships with macOS 27. See [Apple's CLI introduction](https://developer.apple.com/videos/play/wwdc2026/334/) and the [`fm serve` API notes](https://github.com/llostinthesauce/fm-guide/blob/main/docs/serve-api.md).

#### Microsoft Foundry Local on Windows or Linux

Install the current CLI for your platform from the [Foundry Local releases](https://github.com/microsoft/foundry-local/releases). Start its OpenAI-compatible server and load a catalog model:

```sh
foundry server start --port 39839
foundry model load qwen3-0.6b
foundry server status
```

Run this from Linux or WSL, using the server address reachable from that environment:

```sh
ai-renamer /path/to/sample.txt --provider=local --base-url=http://127.0.0.1:39839
```

Foundry Local runs models from its own catalog. See the [Foundry Local CLI reference](https://learn.microsoft.com/en-us/azure/foundry-local/reference/reference-cli).

#### Ollama

Install and start [Ollama](https://ollama.com/download), then download a model and rename a disposable file:

```sh
ollama pull gemma3:4b
sample_dir=$(mktemp -d)
printf '%s\n' 'Quarterly sales report for the home appliances division.' > "$sample_dir/sample.txt"
ai-renamer "$sample_dir/sample.txt" --provider=ollama --base-url=http://127.0.0.1:11434 --model=gemma3:4b
```

The command renames the file in place and prints a run ID. Use `ai-renamer --list-runs` to find it and `ai-renamer --rollback RUN_ID` to restore the original name. To build from source or develop in a Dev Container or BoxD VM, see the [contributor guide](CONTRIBUTING.md).

## Document extraction with Docling

Point the CLI at a running [Docling Serve](https://docling.org/serve/) instance:

```sh
export DOCLING_SERVE_URL=http://localhost:5001
export DOCLING_SERVE_API_KEY=your-key  # Only if the instance requires it
ai-renamer /path/to/documents --include-subdirectories=true
```

Files such as PDFs, Word documents, PowerPoint presentations, Excel workbooks, OpenDocument files, and selected markup formats go to Docling's multipart `/v1/convert/file` endpoint. The model receives the extracted Markdown, up to 65,536 characters. The CLI uploads documents of up to 64 MiB and caps the Docling response at 1 MiB. A failed or empty conversion leaves the original file in place.

### Without Docling

Leave `DOCLING_SERVE_URL` unset to use local file extraction. A model endpoint is still required. Ollama or LM Studio can run locally.

| File type | Behavior without Docling |
| --- | --- |
| Supported text and source files, including Markdown, HTML, and CSV | Reads the file directly and sends its text to the configured model. |
| Supported images, including JPEG, PNG, BMP, and TIFF | Sends the image to a vision-capable model. |
| Supported videos | Requires `ffmpeg` and `ffprobe` to extract frames for a vision-capable model. |
| PDFs | Requires Poppler's `pdftotext` and a usable text layer. Image-only scans stay untouched unless OCR text is already embedded or Docling is configured. |
| Word documents, Excel workbooks, PowerPoint presentations, and other Docling-only formats | Leave the files untouched and report that `DOCLING_SERVE_URL` is required. |

Recursive scanning, parallel jobs, collision protection, and rollback work without Docling. File extraction happens locally in this mode. File text, images, or sampled frames still go to the model endpoint you select.

## BendHub packages

All direct imports are pinned by content hash. The first source build may fetch them from BendHub.

| Package | Used for |
| --- | --- |
| [ezjson](https://hub.bend-lang.com/0x597f8af3f77d8983aacfa076df42d235) | Provider requests and responses, Docling responses, and settings |
| [shake](https://hub.bend-lang.com/0x64697f57fea19681b5fa4f87014ce63d) | Argument parsing, option validation, and help |
| [bend-kit-files](https://hub.bend-lang.com/0x5fea041be86f1677bfed779e7579233f) | POSIX filename extension handling |
| [bend-kit-time](https://hub.bend-lang.com/0x0d2a146cd1cbaedf76cc532bcd3594b0) | Monotonic time for progress and ETA |
| [bend-kit-process](https://hub.bend-lang.com/0x92957abd83651a4f5b5d352560a37e03) | Bounded FFprobe execution |
| [bend-kit-bytes](https://hub.bend-lang.com/0xec25e4adfb02e59e4b817801115988ee), [bend-kit-encoding](https://hub.bend-lang.com/0xe0126415561194eca594bb57287bdd1d) | FFprobe output buffers and UTF-8 decoding |
| [bend-mathlib](https://hub.bend-lang.com/0x15432fae482a0916f1cfffa8b5e1a335) | Proof that filename length obeys the configured limit |
| [bend-kit-property](https://hub.bend-lang.com/0xcb49218c6a354d080bcff793a688eccc), [bend-kit-random](https://hub.bend-lang.com/0x46b9429cbffa7a8c1111ce19c60a3d6a) | Reproducible generated filename tests |

## Rename and undo

```sh
ai-renamer /path --provider=ollama --model=llava:latest --jobs=32
ai-renamer /path --provider=lm-studio --base-url=http://127.0.0.1:1234
ai-renamer /path --provider=openai --api-key="$OPENAI_API_KEY" --model=gpt-4o
ai-renamer /path --include-subdirectories=true --case=snakeCase
ai-renamer --list-runs
ai-renamer --rollback RUN_ID
```

Existing settings in `~/ai-renamer.json` carry over. The worker pool defaults to 16 concurrent jobs and supports 1–64. Files stay in the same directory. Concurrent files with identical suggestions can get numeric suffixes in completion order.

The CLI prints a run ID before renaming. Before each move, it writes and syncs a journal entry containing both names, the directory and file identity, and a SHA-256 fingerprint. It uses the filesystem's exclusive rename operation so an existing destination cannot be overwritten. If the filesystem cannot perform that operation, the CLI reports an error.

The journals live at `$XDG_STATE_HOME/ai-renamer` or `~/.local/state/ai-renamer`. Keep them to undo a run, including one interrupted by a crash. Rollback processes the run in reverse order and skips moves it already reversed. It reports conflicts when an original name is occupied or when the renamed file was moved, replaced, or edited. Journals restore names for files that still exist at their recorded locations. They contain no file data.

## Checks and releases

```sh
bend PROOF.bend
make test
make verdict  # Optional. Requires Lean v4.34.0 or BENDTT.
```

GitHub Actions checks the Bend laws and runs CLI tests on Linux and macOS, for both amd64 and arm64. Pushing a `v*` tag publishes one executable per platform in its own archive, plus checksums, after those checks pass. The integration suite uses local mock model and Docling endpoints and tests parallel requests, conversion failures, collisions, interrupted runs, and rollback conflicts.

Based on the GPL-3.0 project [ozgrozer/ai-renamer](https://github.com/ozgrozer/ai-renamer) by Ozgur Ozer.

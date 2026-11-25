# ai-renamer

A native Bend CLI that renames files from their contents using Ollama, LM Studio, or OpenAI. It handles images, videos, documents, and text or source files. It includes the progress bar, ETA, and recursive traversal from [upstream PR #27](https://github.com/ozgrozer/ai-renamer/pull/27).

## Install

Get the Linux or macOS archive for your architecture from [Releases](https://github.com/barakplasma/ai-renamer/releases), or build it with Bend 2.0.40, Clang, Make, and the libcurl headers. Linux also uses the OpenSSL development headers.

```sh
make
make install PREFIX="$HOME/.local"
```

The output is one `.build/ai-renamer` executable. Bend handles the CLI, filename rules, scheduling, model payloads, and rollback decisions. Direct C effects use libcurl for HTTP and the OS filesystem APIs for reads, journal writes, and exclusive renames. Python is only used by the test suite. Video uses FFmpeg and FFprobe. PDF can use Docling or Poppler's `pdftotext`.

## Document extraction with Docling

Point the CLI at a running [Docling Serve](https://docling.org/serve/) instance:

```sh
export DOCLING_SERVE_URL=http://localhost:5001
export DOCLING_SERVE_API_KEY=your-key  # Only if the instance requires it
ai-renamer /path/to/documents --include-subdirectories=true
```

Files such as PDFs, Word documents, PowerPoint presentations, Excel workbooks, OpenDocument files, and selected markup formats go to Docling's multipart `/v1/convert/file` endpoint. The model receives the extracted Markdown, up to 65,536 characters. The CLI uploads documents of up to 64 MiB and caps the Docling response at 1 MiB. A failed or empty conversion leaves the original file in place. Without a Docling URL, PDFs use `pdftotext`, text formats already supported by the CLI stay local, and formats that need Docling report a configuration error.

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

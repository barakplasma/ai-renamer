# ai-renamer

A native Bend CLI that renames files from their contents using Ollama, LM Studio, or OpenAI. It handles images, videos, PDFs, and text or source files. It includes the progress bar, ETA, and recursive traversal from [upstream PR #27](https://github.com/ozgrozer/ai-renamer/pull/27).

## Install

Get the Linux or macOS archive for your architecture from [Releases](https://github.com/barakplasma/ai-renamer/releases), or build it with Bend 2.0.40, Clang, Make, and the libcurl headers. Linux also uses the OpenSSL development headers.

```sh
make
make install PREFIX="$HOME/.local"
```

The output is one `.build/ai-renamer` executable. Bend handles the CLI, filename rules, scheduling, model payloads, and rollback decisions. Direct C effects use libcurl for HTTP and the OS filesystem APIs for reads, journal writes, and exclusive renames. [ezjson](https://hub.bend-lang.com/0x597f8af3f77d8983aacfa076df42d235) handles model and settings JSON and is pinned by its BendHub content hash. Python is only used by the test suite. Video uses FFmpeg and FFprobe, and PDF uses Poppler's `pdftotext`.

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

GitHub Actions checks the Bend laws and runs CLI tests on Linux and macOS, for both amd64 and arm64. Pushing a `v*` tag publishes one executable per platform in its own archive, plus checksums, after those checks pass. The integration suite uses local model endpoints and tests parallel requests, collisions, interrupted runs, and rollback conflicts.

Based on the GPL-3.0 project [ozgrozer/ai-renamer](https://github.com/ozgrozer/ai-renamer) by Ozgur Ozer.

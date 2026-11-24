# ai-renamer

A native Bend CLI that renames files from their contents using Ollama, LM Studio, or OpenAI. It handles images, video frames, PDFs, and text or source files. It includes the progress bar, ETA, and recursive directory tracking from [PR #27](https://github.com/ozgrozer/ai-renamer/pull/27).

## Build and run

Install [Bend 2.0.40](https://bend-lang.com/), Clang, Make, and Python 3.8 or newer. Use Linux or macOS. Video needs FFmpeg and FFprobe. PDFs need Poppler's `pdftotext`.

```sh
make
PATH="$PWD/host:$PATH" .build/ai-renamer /path/to/files --model=llava:latest --jobs=32
make install PREFIX="$HOME/.local"
```

To run an installed copy, place `$HOME/.local/bin` on your PATH.

```sh
ai-renamer /path --provider=ollama --model=llava:latest
ai-renamer /path --provider=lm-studio --base-url=http://127.0.0.1:1234
ai-renamer /path --provider=openai --api-key="$OPENAI_API_KEY" --model=gpt-4o
ai-renamer /path --include-subdirectories=true --jobs=32 --case=snakeCase
```

The existing `~/ai-renamer.json` settings carry over. Passed options are saved there. Use `ai-renamer --help` for option names and defaults. When names collide, the CLI appends a number before the extension. It skips symlinks. `pathCase` uses hyphens to keep names in their existing directory. Concurrent files that get the same suggestion can receive collision suffixes in completion order.

## Parallel processing

The native build uses a Bend worker pool. Up to 16 workers run by default, with `--jobs` accepting 1–64. Workers independently read files, extract media, ask the model, and apply the names. Each destination is claimed without overwriting an existing file. Completion and ETA are based on the file count from the initial directory scan.

Bend implements the CLI, model selection, naming, and scheduling. The bundled Python standard-library adapter supplies filesystem operations, HTTP and JSON, and media subprocesses. There are no Node.js or npm runtime dependencies.

## Verify

```sh
bend PROOF.bend
make test
```

The integration suite uses local mock model endpoints and checks recursive progress, collision protection, provider payloads, failure behavior, and overlapping requests.

Based on the GPL-3.0 project [ozgrozer/ai-renamer](https://github.com/ozgrozer/ai-renamer) by Ozgur Ozer.

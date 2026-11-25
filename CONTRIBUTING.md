# Developing ai-renamer

## Get a development shell

Clone the fork and check out the Bend rewrite:

```sh
git clone --branch bend-rewrite https://github.com/barakplasma/ai-renamer.git
cd ai-renamer
```

With Docker and the VS Code **Dev Containers** extension, open the repository and choose **Dev Containers: Reopen in Container**. The container installs the pinned Bend compiler, Clang, libcurl and OpenSSL headers, Python, FFmpeg, and Poppler. In the container terminal:

```sh
bend guide
make test
.build/ai-renamer --help
```

The first build fetches the pinned BendHub packages. The tests start their own model and Docling endpoints, so you can run them without credentials or model downloads.

## Develop on BoxD or Ubuntu

Connect to an existing Ubuntu 24.04 BoxD machine with `boxd machine connect MACHINE` and clone the repository inside the VM. Then run this from the repository root:

```sh
export BEND_HOME="$HOME/.local/share/ai-renamer/bend"
sh dev/setup.sh
export PATH="$BEND_HOME/bin:$PATH"
bend guide
make test
```

The bootstrap installs the same dependencies as the Dev Container. It uses root or `sudo` for the system packages. If you supply a custom Bend install path as the script's first argument, use that path in `BEND_HOME`. The same commands work on a local Ubuntu 24.04 machine.

## Work on a change

| Area | Start here |
| --- | --- |
| CLI options and saved settings | [Options.bend](Options.bend), [Prefs.bend](Prefs.bend) |
| File detection and filename rules | [Core.bend](Core.bend) |
| Model and Docling requests | [Model.bend](Model.bend), [effects/media.h](effects/media.h) |
| Scanning, renaming, and recovery | [main.bend](main.bend), [Rollback.bend](Rollback.bend), [effects/journal.h](effects/journal.h) |

Read [LAWS.bend](LAWS.bend) when changing behavior that has a stated guarantee. Update the law and its proof in [PROOF.bend](PROOF.bend) as needed. Run `bend PROOF.bend` before committing and `make test` to build the binary and run the generated filename checks and CLI tests.

Use a disposable copy for a manual rename. A service bound to your laptop's `127.0.0.1` is reachable only from that laptop. When running inside a Dev Container or BoxD VM, pass a model endpoint reachable from that environment with `--base-url`. For optional Docling testing, set `DOCLING_SERVE_URL` to a reachable service there too.

For installation and first use on your own machine, see [Getting started](README.md#getting-started).

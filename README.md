# Upgrade canary

A scheduled check for container images that build green and then do not start.

`canary.sh` builds a Dockerfile the way a fresh release runner would, checks that every executable in the image can load its libraries, starts the image, and tells you which packages moved since the last green run. A preview mode rebuilds on the next value of floating base tags (`node:lts`, `ubuntu:latest`, `python:3`) before the tag moves. It needs Docker with buildx and jq, and ships as a CLI and a composite GitHub Action.

## What it checks

1. **Clean build.** Each run creates its own BuildKit builder (docker-container driver), builds with `--no-cache --pull`, and removes the builder afterwards. Nothing carries over between runs: no layer cache, no `RUN --mount=type=cache` contents, base images resolved again from the registry. With `--builder NAME` it builds on your builder instead and prunes that builder's exec cache mounts first (`docker buildx prune --filter type=exec.cachemount`).
2. **Shared libraries.** Every ELF file under the paths you choose (the whole image by default) is listed with the image's own dynamic loader: glibc's `ld-linux` in trace mode (what `ldd` does) or musl's `ld-musl --list`. An executable fails the check when a library or a symbol version is not found, or when the interpreter it names is missing, as with a musl binary in a glibc image. A static busybox is copied into the container for the scan, so images without a shell work too.
3. **Start.** Runs the image with a smoke command and checks the exit code, or waits for a log line or for a URL to answer 2xx, under a timeout. The URL is fetched from inside the container's network namespace, so no host port is published. With `--compose` it starts your compose file with the new image and checks one service.
4. **Packages.** Writes the runtime package list (syft in a container, or the image's dpkg, apk or rpm database), the packages each build stage installed (from the apk, apt and pip lines in the build log) and the digest each base image resolved to, then diffs them against the last green run. Names are compared with version numbers taken out, so `openssl-3.6-dev 3.6.5-r1` to `openssl-4.0-dev 4.0.3-r6` shows as one change.
5. **Flip preview.** Copies the Dockerfile, moves floating base tags to their next value and runs the same checks on the copy: `node:lts` to `node:26` (variants kept, so `node:lts-slim` becomes `node:26-slim`; since 2026-10-28 these are the same images, see below), `ubuntu:latest` to `ubuntu:26.04`, and `python:3` to the newest `3.x` tag that exists (the `3.N-rc` tag until `3.N` is published, but only once that tag holds a release candidate rather than an alpha or a beta). `--flip FROM=TO` adds your own. A tag that already points at the target image is reported and not rebuilt. The planner looks tags up in the registry; a lookup that fails for any reason other than "not found" (a rate limit, a login error, a network error) is tried again after 2, 5 and 10 seconds (`CANARY_LOOKUP_RETRY` sets the waits, `""` for a single try). If it still fails, it is shown in the plan with the registry's message, no preview is built, and the run exits 2, so a failed lookup is never reported as "nothing to preview".

The summary is Markdown on stdout, and is appended to `$GITHUB_STEP_SUMMARY` when that is set.

## Why

### OpenSSL 4 in Wolfi (October 2026)

On 2026-10-06 at 13:42 UTC, Wolfi's `openssl-dev` began to resolve to `openssl-4.0-dev`. A Dockerfile that installs `openssl-dev` in a Chainguard builder stage and copies `libssl.so.3` into its runtime stage still builds without an error; the binary then cannot start.

- **OpenZeppelin Relayer.** On 2026-10-10 I built `main` at d7f151f with its unmodified `Dockerfile.production`. The build exited 0. The binary exited 127: `libssl.so.4: cannot open shared object file`. The runtime stage copies only `libssl.so.3` and `libcrypto.so.3`. The fix I proposed pins `openssl-3.6-dev` ([OpenZeppelin/openzeppelin-relayer#919](https://github.com/OpenZeppelin/openzeppelin-relayer/pull/919)). The release workflow caches layers (`type=gha`), but only release builds write that cache, the last was v1.8.0 on 2026-08-19, and GitHub drops cache entries unused for 7 days, so the next release build starts cold. No step in that workflow starts the image, so a release built from that commit would ship an image that cannot start.
- **LiteLLM.** [BerriAI/litellm#44991](https://github.com/BerriAI/litellm/pull/44991) pinned `openssl-3.6-dev` for the pgbouncer build stage on 2026-10-07. [#44997](https://github.com/BerriAI/litellm/pull/44997) reverted it 98 minutes later: with the pin, pgbouncer links `libssl.so.3`, no runtime stage installs it, and the current `wolfi-base` ships only `libssl.so.4`, so "the next digest bump makes pgbouncer exit 127 while the build stays green".

Build caches make this harder to see. `RUN --mount=type=cache` keeps cargo's target directory between builds, and cargo does not relink when only a system library changes, so a rebuild on a warm builder can reuse a binary linked against the previous OpenSSL. My first rebuild of the Relayer fix did exactly that and finished in 4.7 seconds with the old binary. In my tests (BuildKit 0.12.5, 0.26.2 and 0.33.1, each on a docker-container builder) `--no-cache` did start each `RUN` with an empty cache mount, and later builds kept what that run wrote; ordinary rebuilds kept the old contents even when the step itself re-ran because something before it changed. The canary does not depend on either behaviour: every run gets a builder of its own.

### A published image whose JavaScript scripts cannot run (October 2026)

`openzeppelin/openzeppelin-monitor:v1.6.0` starts, and `--help` exits 0, so a start check alone passes. The library check does not: run against the published image on 2026-10-11, it failed 2 of the image's 153 ELF files, and noted a third, the shared object `/usr/lib/libjq.so.1.0.4`, with the same missing symbol version. `/usr/bin/node` and `/usr/bin/jq` need `libm.so.6(GLIBC_2.43)`, and the image's runtime base pins `glibc 2.42-r7`. Monitor runs JavaScript trigger scripts and conditions through `node`, so in this image they error out, and a JavaScript trigger condition passes every match on unfiltered. I reported it with a tested fix (a current `wolfi-base` digest) as [OpenZeppelin/openzeppelin-monitor#502](https://github.com/OpenZeppelin/openzeppelin-monitor/issues/502). From that run's summary:

| Check | Result | Detail |
|---|---|---|
| Clean build | skip | existing image openzeppelin/openzeppelin-monitor:v1.6.0 |
| Shared libraries | **FAIL** | 2 of 153 ELF files cannot load |
| Start | pass | exited 0 |
| Packages | info | 801 entries listed; no previous list to compare |

Monitor 1.7.0, released on 2026-10-22, fixes it ([OpenZeppelin/openzeppelin-monitor#506](https://github.com/OpenZeppelin/openzeppelin-monitor/pull/506) moves the script runtime to Node.js 24). Run against the published `v1.7.0` image the same day, the library check passes, 158 of 158 ELF files resolve, and `node` (v24.22.1) and `jq` (1.8.2) run. With the 1.6.0 list as the previous run, the package diff shows what changed underneath: `ld-linux` 2.42-r7 to `ld-linux-2.44` 2.44-r8, and `nodejs-26` 26.5.0 to `nodejs-24` 24.22.1.

### pnpm 12

`npm install -g pnpm` now installs pnpm 12. The Relayer's `main` pins `pnpm@10` with the comment "pnpm 12 ships a preinstall script that newer npm blocks by default, which leaves a broken pnpm shim". When I built the branch of OpenZeppelin/openzeppelin-relayer#862 on 2026-10-10, which predates that pin, `pnpm install` failed with `ERR_PNPM_IGNORED_BUILDS` on esbuild until I pinned `pnpm@10`. Nothing in the branch had changed; the package manager had. A scheduled clean build shows this on the day it happens, and the package diff names the version that moved when the build still passes.

### Tags that move on a date

- `node:lts` moved to Node 26 on 2026-10-28. The change was merged into Docker's official images at 20:49 UTC ([docker-library/official-images#22615](https://github.com/docker-library/official-images/pull/22615)), and Docker Hub's `lts`, `lts-slim` and `lts-alpine` tags were pushed at 23:43 UTC with the same digests as `node:26`, `node:26-slim` and `node:26-alpine`. Node 26 images ship without yarn ([nodejs/docker-node#2422](https://github.com/nodejs/docker-node/pull/2422)) and without corepack, and `node:lts-slim` moved from Debian 12 to Debian 13. The fixture in `tests/fixtures/node-corepack` passed on `node:lts-slim` while it was Node 24 (24.22.1 on 2026-10-22) and failed in the preview with `corepack: not found`. On 2026-10-29 its build on the real `node:lts-slim` (Node 26.13.0) failed the same way, and `Dockerfile.fixed` next to it, which installs corepack from npm, passed. Since the move the preview's node rule (`node:lts` to `node:26`) finds the same image and builds nothing. An image still pinned to Node 24 can preview the move with `--flip node:24-slim=node:26-slim`, as `Dockerfile.node24` in the same directory does in the tests and the self-check. The next move, to Node 27, is scheduled for 2027-10-20 ([nodejs/Release schedule](https://github.com/nodejs/Release/blob/main/schedule.json)); until the built-in rule names Node 27, `--flip` previews that move once Node 27 images exist.
- The Docker tag `ubuntu:latest` already has the same digest as `ubuntu:26.04` (checked 2026-10-11 and again on 2026-10-22), so the preview reports it as the same image and builds nothing. An image still pinned to the previous release can preview the move with `--flip ubuntu:24.04=ubuntu:26.04`: on a copy of the Ubuntu fixture with `FROM ubuntu:24.04`, both builds pass, and curl goes from 8.5.0 to 8.18.0 and OpenSSL from 3.0.13 to 3.5.5 among 123 changed, 27 added and 4 removed packages (run on 2026-10-22). The GitHub runner label `ubuntu-latest` moves to Ubuntu 26.04 between 2026-10-19 and 2026-11-19 ([actions/runner-images#14748](https://github.com/actions/runner-images/issues/14748)); a container cannot preview that, so the example workflow below runs on `ubuntu-26.04` as well.
- `python:3` now points at 3.15 (3.15.1 on 2026-10-22), the newest release, so the Python preview has nothing to build. `python:3.16-rc` exists but holds 3.16.0a1, an alpha that few packages publish wheels for, so the planner reports it and waits for a 3.16 release candidate.

## Usage

```sh
~/upgrade-canary/canary.sh [options] [CONTEXT]
```

The examples run the script from a clone of this repository at `~/upgrade-canary` (`git clone https://github.com/zachsplat/upgrade-canary ~/upgrade-canary`), in the directory that holds your Dockerfile. Call it by that path: it finds `lib/` next to itself (a symlink to it from another directory does not), and it writes `.canary/` in the directory you run it from.

Build the current directory's `Dockerfile`, check libraries, check that the default command does not crash in its first 10 seconds:

```sh
~/upgrade-canary/canary.sh .
```

A service with a health URL and a preview of a base tag move, here the fixture pinned to Node 24 previewed on Node 26 (`--flip-preview` alone moves the floating tags listed above):

```sh
~/upgrade-canary/canary.sh --ready-url http://localhost:3000/health \
  -f ~/upgrade-canary/tests/fixtures/node-corepack/Dockerfile.node24 \
  --flip node:24-slim=node:26-slim ~/upgrade-canary/tests/fixtures/node-corepack
```

A service that needs other containers. The compose file uses `image: ${CANARY_IMAGE}` for the service under test (see `examples/openzeppelin-relayer`):

```sh
~/upgrade-canary/canary.sh -f Dockerfile.production \
  --compose ~/upgrade-canary/examples/openzeppelin-relayer/compose.yml --service relayer \
  --ready-url http://localhost:8080/api/v1/health --timeout 120 .
```

A command that must exit 0, and an image that is already built or published:

```sh
~/upgrade-canary/canary.sh --smoke "--version" .
~/upgrade-canary/canary.sh --image openzeppelin/openzeppelin-relayer:v1.8.0 --no-start
```

This is the summary for the Relayer at d7f151f on 2026-10-11, abridged (paths and the package source line removed). The previous package list it diffs against came from a run of the pinned branch (30b32b1) a few minutes earlier:

```markdown
## Upgrade canary: openzeppelin-relayer main d7f151f (unmodified): FAIL

| Check | Result | Detail |
|---|---|---|
| Clean build | pass | 6 min 30 s, nw-relayer:canary-main-d7f151f, 646MB |
| Shared libraries | **FAIL** | 1 of 47 ELF files cannot load |
| Start | **FAIL** | exited 127 before http://localhost:8080/api/v1/health answered |
| Packages | info | 1 changed, 4 added, 0 removed since 20261011-043606-233134 |

### Shared libraries

47 ELF files under `/`, loader `/lib64/ld-linux-x86-64.so.2`: 41 resolve, 3 static, 1 executable with missing libraries, 2 built for the other C library (skipped).

Cannot load:

- `/app/openzeppelin-relayer`: libssl.so.4 libcrypto.so.4

### Start

Last log lines:

/app/openzeppelin-relayer: error while loading shared libraries: libssl.so.4: cannot open shared object file: No such file or directory

### Package changes since run 20261011-043606-233134

| Where | Package | Change | Before | After |
|---|---|---|---|---|
| build, stage `base`, apk | openssl-dev | changed | openssl-3.6-dev 3.6.5-r1, openssl-dev 3.6.5-r2 | openssl-4.0-dev 4.0.3-r6 |
| build, stage `base`, apk | libbrotlienc | added | - | libbrotlienc1 1.2.0-r5 |
| build, stage `base`, apk | openssl-libcrypto | added | - | openssl-4.0-libcrypto 4.0.3-r6 |
| build, stage `base`, apk | openssl-libssl | added | - | openssl-4.0-libssl 4.0.3-r6 |
| build, stage `base`, apk | openssl-provider-legacy-allowed | added | - | openssl-provider-legacy-allowed 4.0.3-r1 |
```

Run again at 19:20 UTC the same day, the pinned branch still passed, and its diff against the 04:36 run named the one thing Wolfi had moved in between, brotli: `libbrotlicommon1`, `libbrotlidec1` and `libbrotlienc1` from 1.2.0-r5 to 1.2.0-r6.

Only print what the preview would substitute:

```sh
~/upgrade-canary/canary.sh --flip-plan -f Dockerfile .
```

`~/upgrade-canary/canary.sh --help` lists every option. The ones you will want most:

| Option | What it does |
|---|---|
| `-f FILE`, `--target`, `--build-arg K=V` | what to build |
| `--elf-paths "P ..."`, `--elf-exclude REGEX`, `--strict-libs` | where to look for ELF files; `--strict-libs` also fails shared objects with missing libraries |
| `--smoke "ARGS"`, `--entrypoint`, `--expect-exit N` | run a command and check its exit code |
| `--ready-log REGEX`, `--ready-url URL`, `--timeout SEC` | wait for the service instead |
| `--compose FILE --service NAME` | start a compose file with the new image |
| `--flip-preview`, `--flip FROM=TO`, `--flip-warn-only` | the preview |
| `--state-dir DIR`, `--previous FILE`, `--fail-on-change` | where the last green package list lives |
| `--registry-mirror HOST`, `--cpus N`, `--memory SIZE` | for rate limits and shared machines |

Exit status: 0 pass, 1 a check failed, 2 usage or setup error (also when a registry lookup for the preview fails), 3 the preview failed while the current build passed, 4 packages changed (with `--fail-on-change`).

Each run writes `.canary/runs/<run>/` (the summary, the build log, the library scan, the start log, the package lists and the diffs as JSON) and, when the current build passes, `.canary/last-green.json` for the next run to diff against. The built image stays in Docker as `canary/<name>:<run>` (`-flip` appended for the preview, or your `--tag`) and old run directories are kept, so a machine that runs this on a schedule gains one image per run (two with the preview). They are tagged, so `docker image prune` without `-a` leaves them; remove them with `docker image ls --format '{{.Repository}}:{{.Tag}}' 'canary/*' | xargs -r docker rmi`, and clear `.canary/runs/` now and then. With a fixed `--tag`, each run untags the previous image instead, and `docker image prune` does remove those.

## GitHub Action

`action.yml` wraps the CLI. It restores the last green package list from the Actions cache, runs the checks, saves the list again and uploads the run directory as an artifact. `@v1` follows the v1 releases; pin a commit SHA if you prefer, or use `@main` to follow every change I push to `main`. A copy of this repository under `.github/actions/canary` in yours, referenced by that path, works too.

```yaml
name: upgrade canary

on:
  schedule:
    - cron: "23 5 * * *"
  workflow_dispatch:

permissions:
  contents: read

jobs:
  canary:
    strategy:
      fail-fast: false
      matrix:
        runner: [ubuntu-latest, ubuntu-26.04]
    runs-on: ${{ matrix.runner }}
    steps:
      - uses: actions/checkout@v7
      - uses: zachsplat/upgrade-canary@v1
        with:
          name: app-${{ matrix.runner }}
          dockerfile: Dockerfile
          ready-url: http://localhost:8080/health
          timeout: "90"
          flip-preview: "true"
```

Inputs mirror the CLI options (`dockerfile`, `context`, `target`, `build-args` one per line, `image`, `elf-paths`, `elf-exclude`, `strict-libs`, `smoke`, `entrypoint`, `expect-exit`, `ready-log`, `ready-url`, `run-args` one per line, `compose`, `service`, `timeout`, `settle`, `sbom`, `flip-preview`, `flips` one per line, `flip-warn-only`, `fail-on-change`, `registry-mirror`, `cpus`, `name`, `upload-artifact`). Outputs: `result` (pass, fail, flip-fail, changed, or error when a registry lookup for the preview failed), `summary`, `image`, `changed`. Give each matrix entry its own `name`, since the cache key and the artifact name come from it. Scheduled workflows run on the default branch, and the Actions cache is evicted after 7 days without use, so a daily or weekly schedule keeps the baseline.

## Requirements

Linux, Docker with buildx 0.13 or later and the docker-container driver (and the Docker Compose plugin for `--compose`), bash 4.4 or later, jq, awk, xargs and coreutils. syft runs from its own image (`ghcr.io/anchore/syft`, pinned by digest) and needs the local Docker socket; the scan helper is `busybox:1.38.0-musl`, also pinned by digest.

## Limits

- One platform per run, the host's architecture. Images for another CPU are not emulated.
- The library check lists what the loader resolves at start. Libraries a program opens later with `dlopen` are not seen, and glibc's trace mode checks symbol versions but not every symbol (musl's `--list` does report missing symbols).
- Shared objects with missing libraries, such as plugins and language extension modules, are notes rather than failures unless you pass `--strict-libs`. The official `python:3.12-slim` image, for example, ships a `_tkinter` module whose Tk libraries are not installed.
- The preview knows `node:lts`, `ubuntu:latest` and `python:3` tags (with their variants). FROM lines set by a build argument or pinned by digest are not substituted; pass `--build-arg` or `--flip` for those.
- Every run is a cold build, by design. The Relayer's took between 5 min 27 s and 6 min 51 s on 6 CPUs.
- Docker Hub limits anonymous pulls per address (100 an hour when I hit it on 2026-10-11), and a cold builder pulls every base image on every run. Log in first, or pass `--registry-mirror mirror.gcr.io`. When the limit is hit during the preview's tag lookups, each lookup is tried four times over 17 seconds, then the run says so and exits 2.
- syft needs the local Docker socket. With a remote `DOCKER_HOST` the runtime list comes from the image's package database.
- Package families are matched by name with version numbers removed. A package that was renamed outright shows as one removal and one addition, and two different packages whose names differ only by a number are paired: Ubuntu 26.04's curl links libssh2 where 24.04's linked libssh, and the diff shows that as `libssh-4` changing to `libssh2-1t64`.
- `--builder NAME` prunes every exec cache mount on that builder, including other projects' ones.
- The start check is a smoke test, not your test suite.

## Tests

`tests/run.sh` builds the fixtures in `tests/fixtures` and checks the verdicts: a passing Alpine image, a binary copied without its library (glibc and musl), a musl binary in a glibc image, the cache mount behaviour, every start check mode, how `--smoke` is split into words, the package diff and build log parsers, the flip planner, the node and ubuntu previews, and, against a stand-in registry (`tests/fixtures/stub-registry`), the `node:lts` move (a flip while the digests differ, the same image after), a failed lookup (Docker Hub's 429), the retries (a 502 that clears on the third try, the default waits, a single try), and the Python release candidate rule. `tests/run.sh --list` names them; pass names to run a subset.

## License

MIT, see `LICENSE`.

If you would rather I run it on a schedule for you and send the fix as a pull request: $99 per image a month, or $299 for five. Write to hello@nonceworks.com.

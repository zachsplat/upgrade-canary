#!/usr/bin/env bash
# Runs the fixtures in tests/fixtures through canary.sh and checks the results.
#
# usage: tests/run.sh [TEST...]   (default: all; list them with --list)
#
# Needs what canary.sh needs (Docker with buildx, jq). The builds are small
# (busybox, Alpine, Debian slim, Node slim, Ubuntu); the node and ubuntu tests
# also build a flip preview, and lookup_error, lookup_retry, node_moved and
# python_rc answer registry lookups from a stand-in (tests/fixtures/stub-registry). Set
# CANARY_REGISTRY_MIRROR=mirror.gcr.io if Docker Hub rate limits get in the
# way, and KEEP_IMAGES=1 to keep the test images.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CANARY=$HERE/../canary.sh
FX=$HERE/fixtures
LIB=$HERE/../lib
REAL_DOCKER=$(command -v docker)
export REAL_DOCKER
STUB=$FX/stub-registry
HELPER=$(sed -n "s/^HELPER_IMAGE_DEFAULT='\(.*\)'$/\1/p" "$CANARY")
export CANARY_PREFIX=${CANARY_PREFIX:-canary-test}
# lookup_error and lookup_retry set their own waits; every other test gets the
# defaults
unset CANARY_LOOKUP_RETRY
P=$CANARY_PREFIX
T=$(mktemp -d "${TMPDIR:-/tmp}/canary-tests.XXXXXX")
PASSED=0
FAILED=0
FAILED_NAMES=()

ok() { PASSED=$((PASSED + 1)); printf '  ok    %s\n' "$*"; }
bad() { FAILED=$((FAILED + 1)); FAILED_NAMES+=("$CURRENT"); printf '  FAIL  %s\n' "$*"; }

cleanup() {
	docker buildx rm "$P-cachemount" >/dev/null 2>&1
	if [ "${KEEP_IMAGES:-0}" != 1 ]; then
		docker images --format '{{.Repository}}:{{.Tag}}' | grep "^$P/" | xargs -r docker rmi -f >/dev/null 2>&1
	fi
	rm -rf "$T"
}
trap cleanup EXIT

# run NAME WANT_EXIT ARGS...: runs canary.sh, keeps the summary in $T/NAME.md
run() {
	local name=$1 want=$2 got
	shift 2
	"$CANARY" --state-dir "$T/state-$name" "$@" >"$T/$name.md" 2>"$T/$name.err"
	got=$?
	if [ "$got" = "$want" ]; then
		ok "$name exits $got"
	else
		bad "$name exits $got, expected $want"
		sed 's/^/        /' "$T/$name.err" | tail -n 5
		sed 's/^/        /' "$T/$name.md" | head -n 20
	fi
}

# has NAME TEXT: the summary of NAME contains TEXT
has() {
	if grep -qF -- "$2" "$T/$1.md"; then ok "$1 says: $2"; else bad "$1 does not say: $2"; fi
}

lacks() {
	if grep -qF -- "$2" "$T/$1.md"; then bad "$1 should not say: $2"; else ok "$1 does not say: $2"; fi
}

# logs NAME TEXT: the stderr of NAME contains TEXT
logs() {
	if grep -qF -- "$2" "$T/$1.err"; then ok "$1 logs: $2"; else bad "$1 does not log: $2"; fi
}

# tried FILE N LOOKUP: the stand-in answered LOOKUP ("Manifest REF" or
# "Image REF") N times
tried() {
	local got
	got=$(grep -cxF -- "$3" "$1")
	if [ "$got" = "$2" ]; then ok "$3 looked up $got times"; else bad "$3 looked up $got times, expected $2"; fi
}

t_pkgdiff() {
	jq -n --slurpfile old "$FX/pkgdiff/old.json" --slurpfile new "$FX/pkgdiff/new.json" -f "$LIB/pkgdiff.jq" >"$T/pkgdiff.json"
	local counts row
	counts=$(jq -c .counts "$T/pkgdiff.json")
	if [ "$counts" = '{"changed":4,"added":1,"removed":1}' ]; then ok "pkgdiff counts $counts"; else bad "pkgdiff counts $counts"; fi
	row=$(jq -r '.changes[] | select(.family == "openssl-dev") | "\(.change): \(.before) -> \(.after)"' "$T/pkgdiff.json")
	if [ "$row" = "changed: openssl-3.6-dev 3.6.5-r1 -> openssl-4.0-dev 4.0.3-r6" ]; then ok "pkgdiff pairs openssl-3.6-dev with openssl-4.0-dev"; else bad "pkgdiff openssl row: $row"; fi
	row=$(jq -r '.changes[] | select(.family == "libssl") | .after' "$T/pkgdiff.json")
	if [ "$row" = "libssl3t64 3.5.3-1ubuntu1" ]; then ok "pkgdiff keeps libssl3t64 as one package"; else bad "pkgdiff libssl row: $row"; fi
}

t_buildlog() {
	if awk -f "$LIB/buildlog.awk" "$FX/buildlog/sample.log" | diff -u "$FX/buildlog/expected.tsv" - >"$T/buildlog.diff"; then
		ok "build log parser output matches"
	else
		bad "build log parser output differs"
		sed 's/^/        /' "$T/buildlog.diff" | head -n 20
	fi
}

t_flip_plan() {
	run flip-plan 0 --flip-plan -f "$FX/flip-plan/Dockerfile" "$FX/flip-plan"
	# the node rule's target; whether the registry gives flip or same (node:lts
	# has been node:26 since 2026-10-28) is checked against a stand-in in
	# t_node_moved, so this test does not depend on where the tags point today
	has flip-plan '| 3 | `node:lts` | `node:26` |'
	has flip-plan '| 4 | `node:lts-slim` | `node:26-slim` |'
	has flip-plan '`ubuntu:26.04`'
	# python:3-slim previews the next minor, or none until it has a release
	# candidate; t_python_rc checks both against a stand-in registry
	has flip-plan '| 7 | `python:3-slim` |'
	lacks flip-plan '| error |'
	lacks flip-plan '| missing |'
	has flip-plan '| 8 | `python:3.14` | - | none |'
	has flip-plan 'set by a build argument'
	has flip-plan 'pinned by digest'
	has flip-plan '| 11 | `deps` | - | skip | earlier build stage |'
	has flip-plan '| 12 | `scratch` | - | skip |'
	has flip-plan '| 13 | `alpine:3.22` | - | none |'
	has flip-plan 'node:26-alpine3.19 does not exist; using node:26-alpine'
}

# A lookup that fails for any reason other than "not found" is an error, never
# "missing" or "nothing to preview", once its retries are used up.
# tests/fixtures/stub-registry/docker stands in for docker and answers every
# lookup with Docker Hub's 429; the retries wait 0 s here.
t_lookup_error() {
	local out=$T/lookup-run.out calls=$T/lookup-429.calls
	: >"$calls"
	STUB_REGISTRY=429 STUB_CALLS=$calls PATH=$STUB:$PATH CANARY_REGISTRY_MIRROR= CANARY_LOOKUP_RETRY="0 0 0" \
		run lookup-429 2 --flip-plan -f "$STUB/Dockerfile" "$STUB"
	has lookup-429 '| 1 | `python:3-slim` | - | error | python:3-slim: unexpected status from HEAD request to https://registry-1.docker.io/v2/library/python/manifests/3-slim: 429 Too Many Requests (rate limited; log in with docker login, or pass --registry-mirror mirror.gcr.io for Docker Hub images; tried 4 times) |'
	has lookup-429 '| 2 | `node:lts-slim` | `node:26-slim` | error | node:26-slim: unexpected status'
	has lookup-429 '| 3 | `ubuntu:latest` | `ubuntu:26.04` | error |'
	has lookup-429 '| 4 | `node:lts-alpine3.19` | `node:26-alpine3.19` | error |'
	lacks lookup-429 'was not found in the registry'
	tried "$calls" 4 'Image python:3-slim'
	tried "$calls" 4 'Manifest node:26-slim'
	tried "$calls" 4 'Manifest ubuntu:26.04'
	tried "$calls" 4 'Manifest node:26-alpine3.19'
	logs lookup-429 'registry lookup of node:26-slim failed (unexpected status'
	# a full run: the image itself passes, the preview cannot be planned
	: >"$out"
	GITHUB_OUTPUT=$out STUB_REGISTRY=429 PATH=$STUB:$PATH CANARY_REGISTRY_MIRROR= CANARY_LOOKUP_RETRY="0 0 0" \
		run lookup-429-run 2 --image "$HELPER" -f "$STUB/Dockerfile" --flip-preview --no-elf --no-start --sbom none
	has lookup-429-run "PASS now, but the flip preview could not be planned"
	has lookup-429-run "Preview not built: a registry lookup failed"
	lacks lookup-429-run "Nothing to preview"
	if grep -qx 'result=error' "$out"; then ok "lookup-429-run sets result=error"; else bad "lookup-429-run result: $(grep '^result=' "$out")"; fi
}

# Lookups that fail twice and then answer give the plan python_rc gets, and
# "not found" is not tried again. Then the default waits (2, 5 and 10 s) on one
# FROM line, one try with CANARY_LOOKUP_RETRY="", and a bad value.
t_lookup_retry() {
	local calls=$T/lookup-flaky.calls start took
	: >"$calls"
	STUB_REGISTRY=$STUB/alpha.tsv STUB_CALLS=$calls STUB_FAIL_FIRST=2 PATH=$STUB:$PATH CANARY_REGISTRY_MIRROR= CANARY_LOOKUP_RETRY="0 0 0" \
		run lookup-flaky 0 --flip-plan -f "$STUB/Dockerfile" "$STUB"
	has lookup-flaky '| 1 | `python:3-slim` | - | none | python:3-slim is the newest 3.x release (3.15.1); python:3.16-rc-slim holds 3.16.0a1, not a release candidate yet |'
	has lookup-flaky '| 2 | `node:lts-slim` | `node:26-slim` | flip |'
	has lookup-flaky '| 3 | `ubuntu:latest` | `ubuntu:26.04` | same | already the same image (555555555555) |'
	has lookup-flaky 'node:26-alpine3.19 does not exist; using node:26-alpine'
	lacks lookup-flaky '| error |'
	tried "$calls" 3 'Manifest node:26-slim'
	tried "$calls" 3 'Manifest node:26-alpine3.19'
	logs lookup-flaky 'registry lookup of node:26-slim failed (failed to copy: httpReadSeeker: failed open: unexpected status from GET request to https://registry-1.docker.io/v2/library/node/manifests/26-slim: 502 Bad Gateway); trying again in 0 s'
	: >"$calls"
	STUB_REGISTRY=$STUB/alpha.tsv STUB_CALLS=$calls PATH=$STUB:$PATH CANARY_REGISTRY_MIRROR= CANARY_LOOKUP_RETRY="0 0 0" \
		run lookup-missing 0 --flip-plan -f "$STUB/Dockerfile" "$STUB"
	tried "$calls" 1 'Manifest node:26-alpine3.19'
	tried "$calls" 1 'Manifest python:3.16-slim'
	mkdir -p "$T/one-from"
	echo 'FROM node:lts-slim' >"$T/one-from/Dockerfile"
	: >"$calls"
	start=$SECONDS
	STUB_REGISTRY=429 STUB_CALLS=$calls PATH=$STUB:$PATH CANARY_REGISTRY_MIRROR= \
		run lookup-default 2 --flip-plan -f "$T/one-from/Dockerfile" "$T/one-from"
	took=$((SECONDS - start))
	if [ "$took" -ge 17 ] && [ "$took" -lt 40 ]; then ok "lookup-default took $took s (waits 2, 5, 10)"; else bad "lookup-default took $took s, expected 17 to 40"; fi
	tried "$calls" 4 'Manifest node:26-slim'
	logs lookup-default 'trying again in 2 s'
	logs lookup-default 'trying again in 5 s'
	logs lookup-default 'trying again in 10 s'
	has lookup-default 'mirror.gcr.io for Docker Hub images; tried 4 times) |'
	: >"$calls"
	STUB_REGISTRY=429 STUB_CALLS=$calls PATH=$STUB:$PATH CANARY_REGISTRY_MIRROR= CANARY_LOOKUP_RETRY= \
		run lookup-once 2 --flip-plan -f "$T/one-from/Dockerfile" "$T/one-from"
	tried "$calls" 1 'Manifest node:26-slim'
	lacks lookup-once 'tried'
	CANARY_LOOKUP_RETRY="2 x" run lookup-bad-value 2 --flip-plan -f "$T/one-from/Dockerfile" "$T/one-from"
	logs lookup-bad-value "CANARY_LOOKUP_RETRY takes waits in whole seconds, got 'x'"
}

# node:lts-slim against node:26-slim from a stand-in: different digests plan
# as a flip (before 2026-10-28), the same digest as same, and a run then has
# nothing to preview (since 2026-10-28).
t_node_moved() {
	local d=$T/node-moved a=sha256:3333333333333333333333333333333333333333333333333333333333333333 b=sha256:4444444444444444444444444444444444444444444444444444444444444444
	mkdir -p "$d"
	echo 'FROM node:lts-slim' >"$d/Dockerfile"
	printf '%s\n' "node:lts-slim $a -" "node:26-slim $b -" >"$d/before.tsv"
	printf '%s\n' "node:lts-slim $b -" "node:26-slim $b -" >"$d/moved.tsv"
	STUB_REGISTRY=$d/before.tsv PATH=$STUB:$PATH CANARY_REGISTRY_MIRROR= \
		run node-before 0 --flip-plan -f "$d/Dockerfile" "$d"
	has node-before '| 1 | `node:lts-slim` | `node:26-slim` | flip |'
	STUB_REGISTRY=$d/moved.tsv PATH=$STUB:$PATH CANARY_REGISTRY_MIRROR= \
		run node-moved 0 --flip-plan -f "$d/Dockerfile" "$d"
	has node-moved '| 1 | `node:lts-slim` | `node:26-slim` | same | already the same image (444444444444) |'
	STUB_REGISTRY=$d/moved.tsv PATH=$STUB:$PATH CANARY_REGISTRY_MIRROR= \
		run node-moved-run 0 --image "$HELPER" -f "$d/Dockerfile" --flip-preview --no-elf --no-start --sbom none
	has node-moved-run "Nothing to preview: no FROM line moves to a different image."
}

# python:3 previews the 3.(N+1)-rc tag only once it holds a release candidate.
t_python_rc() {
	STUB_REGISTRY=$STUB/alpha.tsv PATH=$STUB:$PATH CANARY_REGISTRY_MIRROR= \
		run python-alpha 0 --flip-plan -f "$STUB/Dockerfile" "$STUB"
	has python-alpha '| 1 | `python:3-slim` | - | none | python:3-slim is the newest 3.x release (3.15.1); python:3.16-rc-slim holds 3.16.0a1, not a release candidate yet |'
	has python-alpha '| 2 | `node:lts-slim` | `node:26-slim` | flip |'
	has python-alpha '| 3 | `ubuntu:latest` | `ubuntu:26.04` | same | already the same image (555555555555) |'
	has python-alpha 'node:26-alpine3.19 does not exist; using node:26-alpine'
	STUB_REGISTRY=$STUB/rc.tsv PATH=$STUB:$PATH CANARY_REGISTRY_MIRROR= \
		run python-rc 0 --flip-plan -f "$STUB/Dockerfile" "$STUB"
	has python-rc '| 1 | `python:3-slim` | `python:3.16-rc-slim` | flip | python:3.16-slim is not tagged yet; using the release candidate tag (3.16.0rc1) |'
}

t_ok_musl() {
	run ok-musl 0 --tag "$P/ok-musl:test" "$FX/ok-musl"
	has ok-musl "| Shared libraries | pass |"
	has ok-musl "| Start | pass | default command exited 0 |"
	# a second run diffs against the first
	run ok-musl-again 0 --state-dir "$T/state-ok-musl" --tag "$P/ok-musl:test2" "$FX/ok-musl"
	has ok-musl-again "### Package changes since run"
}

t_missing_lib() {
	run missing-lib-glibc 1 --tag "$P/missing-lib-glibc:test" "$FX/missing-lib-glibc"
	has missing-lib-glibc '- `/usr/local/bin/curl`: libcurl.so.4'
	has missing-lib-glibc "libcurl.so.4: cannot open shared object file"
	run missing-lib-musl 1 --tag "$P/missing-lib-musl:test" "$FX/missing-lib-musl"
	has missing-lib-musl '- `/usr/local/bin/curl`: libcurl.so.4'
}

t_wrong_libc() {
	run wrong-libc 1 --tag "$P/wrong-libc:test" "$FX/wrong-libc"
	has wrong-libc 'interpreter `/lib/ld-musl-x86_64.so.1` is not in the image'
}

t_cachemount() {
	local b=$P-cachemount out
	local -a opts=()
	if [ -n "${CANARY_REGISTRY_MIRROR:-}" ]; then
		printf '[registry."docker.io"]\n  mirrors = ["%s"]\n' "$CANARY_REGISTRY_MIRROR" >"$T/buildkitd.toml"
		opts=(--buildkitd-config "$T/buildkitd.toml")
	fi
	docker buildx rm "$b" >/dev/null 2>&1
	docker buildx create --name "$b" --driver docker-container ${opts[@]+"${opts[@]}"} --bootstrap >/dev/null 2>&1 || { bad "cannot create builder $b"; return; }
	docker buildx build --builder "$b" -q --load -t "$P/cachemount:warm" --build-arg MARK=first "$FX/cachemount" >/dev/null 2>&1
	docker buildx build --builder "$b" -q --load -t "$P/cachemount:warm" --build-arg MARK=second "$FX/cachemount" >/dev/null 2>&1
	out=$(docker run --rm "$P/cachemount:warm")
	if [ "$out" = first ]; then
		ok "a normal rebuild with MARK=second still carries the cache mount from MARK=first"
	else
		bad "expected the stale cache mount to print first, got '$out'"
	fi
	run cachemount-builder 0 --builder "$b" --tag "$P/cachemount:pruned" --build-arg MARK=third \
		--smoke "cat /mark" --ready-log '^third$' --no-elf --sbom none "$FX/cachemount"
	has cachemount-builder "were pruned first"
	run cachemount-fresh 0 --tag "$P/cachemount:fresh" --build-arg MARK=fourth \
		--smoke "cat /mark" --ready-log '^fourth$' --no-elf --sbom none "$FX/cachemount"
	has cachemount-fresh "removed after the build"
	docker buildx rm "$b" >/dev/null 2>&1
}

t_start_modes() {
	local img=$P/start-modes:test
	run start-settle 0 --tag "$img" --settle 4 "$FX/start-modes"
	has start-settle "default command still running after 4 s"
	run start-url 0 --image "$img" --ready-url http://localhost:8080/health --no-elf --sbom none
	has start-url "answered after"
	run start-url-404 1 --image "$img" --ready-url http://localhost:8080/nope --timeout 8 --no-elf --sbom none
	has start-url-404 "did not answer 2xx within 8 s"
	run start-log 0 --image "$img" --ready-log 'listening on 8080' --no-elf --sbom none
	run start-log-never 1 --image "$img" --ready-log 'never printed' --timeout 5 --no-elf --sbom none
	has start-log-never "no line matched"
	run start-exit 0 --image "$img" --smoke "sh -c 'exit 3'" --expect-exit 3 --no-elf --sbom none
	run start-exit-wrong 1 --image "$img" --smoke "sh -c 'exit 3'" --no-elf --sbom none
	has start-exit-wrong "exited 3, expected 0"
	run start-quotes 0 --image "$img" --smoke "sh -c 'echo \"two words\"'" --ready-log '^two words$' --no-elf --sbom none
	# a smoke string that starts with --version or --help reaches the container as written
	run start-dash-version 0 --image "$img" --entrypoint echo --smoke "--version" --ready-log '^--version$' --no-elf --sbom none
	run start-dash-help 0 --image "$img" --entrypoint echo --smoke "--help me" --ready-log '^--help me$' --no-elf --sbom none
	run start-db 0 --image "$img" --no-start --sbom db
	has start-db "| Start | skip |"
	run start-changed 4 --image "$img" --no-start --sbom db --previous "$FX/pkgdiff/old.json" --fail-on-change
	has start-changed "PASS, but packages changed"
}

# canary.sh splits --smoke with xargs and whatever printf comes first in PATH.
# uutils printf reads --version, --help or -- right after its format as its own
# option where GNU printf does not, so the same line also runs against the
# stand-in in tests/fixtures/uutils-printf.
t_smoke_split() {
	local line p c s want got
	local -a cases=(
		'--version|[--version]'
		'--help|[--help]'
		'--help me|[--help][me]'
		'-- --version|[--][--version]'
		'serve --version|[serve][--version]'
		"sh -c 'exit 3'|[sh][-c][exit 3]"
	)
	line=$(grep -m 1 "mapfile -d '' smoke < <(" "$CANARY")
	if [ -z "$line" ]; then bad "cannot find the line that splits --smoke in canary.sh"; return; fi
	for p in host uutils-stand-in; do
		for c in "${cases[@]}"; do
			s=${c%%|*} want=${c#*|}
			got=$(SMOKE=$s; [ "$p" = host ] || PATH=$FX/uutils-printf:$PATH; eval "$line"
				printf '[%s]' ${smoke[@]+"${smoke[@]}"} | tr '\n' ' ' | cut -c 1-80)
			if [ "$got" = "$want" ]; then ok "$p printf: --smoke \"$s\" splits into $got"
			else bad "$p printf: --smoke \"$s\" splits into $got, expected $want"; fi
		done
	done
}

# The preview end to end: the corepack fixture pinned to Node 24, previewed on
# Node 26 with --flip, since node:lts itself is node:26 now (t_node_moved).
# The fixed Dockerfile passes on node:lts whichever line it points at.
t_node_flip() {
	local df=$FX/node-corepack/Dockerfile.node24
	run node-flip 3 --tag "$P/node-corepack:test" -f "$df" --flip node:24-slim=node:26-slim --ready-url http://localhost:3000/health "$FX/node-corepack"
	has node-flip "PASS now, FAIL in the flip preview"
	has node-flip '| 4 | `node:24-slim` | `node:26-slim` | flip | your --flip |'
	has node-flip "corepack: not found"
	run node-flip-warn 0 --tag "$P/node-corepack:test2" -f "$df" --flip node:24-slim=node:26-slim --flip-warn-only --ready-url http://localhost:3000/health "$FX/node-corepack"
	run node-fixed 0 --tag "$P/node-corepack:test3" -f "$FX/node-corepack/Dockerfile.fixed" --ready-url http://localhost:3000/health "$FX/node-corepack"
}

t_ubuntu_flip() {
	run ubuntu-flip 0 --tag "$P/ubuntu-latest:test" --flip-preview "$FX/ubuntu-latest"
	has ubuntu-flip '`ubuntu:26.04`'
	run ubuntu-back 0 --tag "$P/ubuntu-latest:test2" --flip ubuntu:latest=ubuntu:24.04 "$FX/ubuntu-latest"
	has ubuntu-back "#### Packages, now against the preview"
}

ALL=(pkgdiff buildlog smoke_split flip_plan lookup_error lookup_retry node_moved python_rc ok_musl missing_lib wrong_libc cachemount start_modes node_flip ubuntu_flip)
if [ "${1:-}" = --list ]; then printf '%s\n' "${ALL[@]}"; exit 0; fi
[ $# -gt 0 ] && ALL=("$@")

for t in "${ALL[@]}"; do
	CURRENT=$t
	echo "$t"
	if ! declare -F "t_$t" >/dev/null; then bad "no test named $t"; continue; fi
	"t_$t"
done

echo
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ] || { echo "failed in: $(printf '%s\n' "${FAILED_NAMES[@]}" | sort -u | tr '\n' ' ')"; exit 1; }

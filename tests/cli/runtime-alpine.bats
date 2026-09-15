#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TEST_HOME="$(mktemp -d)"
  LOCK_FIXTURE="$(mktemp)"
  cp "$REPO_ROOT/build/sources.lock" "$LOCK_FIXTURE"
  export NTFSMAC_SOURCES_LOCK="$LOCK_FIXTURE"
  # shellcheck source=../../build/lib/lock.sh
  source "$REPO_ROOT/build/lib/lock.sh"
  # shellcheck source=../../cli/lib/runtime-alpine.sh
  source "$REPO_ROOT/cli/lib/runtime-alpine.sh"
  runtime_alpine_load
}

teardown() {
  rm -rf "$TEST_HOME"
  rm -f "$LOCK_FIXTURE"
}

make_initialized_cache() {
  local base
  base="$(runtime_alpine_cache_path "$TEST_HOME")"
  mkdir -p "$base/rootfs/bin" "$base/rootfs/usr/sbin" "$base/rootfs/usr/local/bin" "$base/rootfs/etc"
  printf '%s' "$ALPINE_RUNTIME_VERSION" > "$base/rootfs.ver"
  : > "$base/rootfs/bin/bash"
  : > "$base/rootfs/usr/sbin/rpc.nfsd"
  : > "$base/rootfs/usr/local/bin/entrypoint.sh"
  : > "$base/rootfs/vmproxy"
  printf 'rpc_pipefs\nnfsd\n' > "$base/rootfs/etc/fstab"
}

@test "derives one digest-only pull reference plus tag-aware cache and marker from sources.lock" {
  [[ "$ALPINE_RUNTIME_REF" == "docker.io/library/alpine@sha256:"* ]]
  [[ "$ALPINE_RUNTIME_BASE_DIR" == "alpine-${ALPINE_RUNTIME_TAG}-"* ]]
  [[ "$ALPINE_RUNTIME_VERSION" == *"digest=${ALPINE_RUNTIME_DIGEST}"* ]]
  [[ "$ALPINE_RUNTIME_VERSION" == *"anylinuxfs="* ]]
  [[ "$ALPINE_RUNTIME_REF" != *"latest"* ]]
  [[ "$ALPINE_RUNTIME_REF" != *":${ALPINE_RUNTIME_TAG}@"* ]]
}

@test "clean initialization is reported without touching disk or starting a download" {
  run runtime_alpine_cache_state "$TEST_HOME"
  [ "$status" -eq 0 ]
  [ "$output" = "not_initialized" ]
  [ ! -e "$TEST_HOME/.anylinuxfs" ]
}

@test "a complete matching cache is reusable offline" {
  make_initialized_cache
  local failing_tools
  failing_tools="$(mktemp -d)"
  printf '#!/bin/bash\nexit 99\n' > "$failing_tools/curl"
  chmod +x "$failing_tools/curl"

  PATH="$failing_tools:$PATH" run runtime_alpine_prepare_cache "$TEST_HOME"
  rm -rf "$failing_tools"
  [ "$status" -eq 0 ]
  [[ "$output" == *"reusing pinned Alpine"* ]]
  [ "$(runtime_alpine_cache_state "$TEST_HOME")" = "initialized" ]
}

@test "legacy cache is retained side-by-side for migration and rollback" {
  mkdir -p "$TEST_HOME/.anylinuxfs/alpine/rootfs"
  run runtime_alpine_prepare_cache "$TEST_HOME"
  [ "$status" -eq 0 ]
  [[ "$output" == *"legacy Alpine cache detected and preserved"* ]]
  [ -d "$TEST_HOME/.anylinuxfs/alpine/rootfs" ]
  [ ! -e "$(runtime_alpine_cache_path "$TEST_HOME")" ]
}

@test "digest or version mismatch is preserved before a fresh initialization" {
  local base
  base="$(runtime_alpine_cache_path "$TEST_HOME")"
  mkdir -p "$base/rootfs"
  printf 'wrong-digest-marker' > "$base/rootfs.ver"

  run runtime_alpine_prepare_cache "$TEST_HOME"
  [ "$status" -eq 0 ]
  [[ "$output" == *"preserved the incompatible"* ]]
  [ ! -e "$base" ]
  compgen -G "${base}.preserved-*" >/dev/null
}

@test "an interrupted initialization is preserved and safely retryable" {
  local base
  base="$(runtime_alpine_cache_path "$TEST_HOME")"
  mkdir -p "$base/oci/blobs"
  printf 'partial' > "$base/oci/blobs/download"

  run runtime_alpine_prepare_cache "$TEST_HOME"
  [ "$status" -eq 0 ]
  [[ "$output" == *"interrupted runs can be retried"* ]]
  [ ! -e "$base" ]
  compgen -G "${base}.preserved-*" >/dev/null
}

@test "upgrade and rollback caches remain independent" {
  make_initialized_cache
  local previous_base
  previous_base="$(runtime_alpine_cache_path "$TEST_HOME")"

  sed -i '' \
    's/^ALPINE_TAG=.*/ALPINE_TAG=3.23.6/; s/^ALPINE_DIGEST=.*/ALPINE_DIGEST=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' \
    "$LOCK_FIXTURE"
  runtime_alpine_load
  local upgraded_base
  upgraded_base="$(runtime_alpine_cache_path "$TEST_HOME")"

  [ "$previous_base" != "$upgraded_base" ]
  [ -d "$previous_base" ]
  run runtime_alpine_prepare_cache "$TEST_HOME"
  [ "$status" -eq 0 ]
  [[ "$output" == *"first run"* ]]
  [ -d "$previous_base" ]
  [ ! -e "$upgraded_base" ]
}

@test "invalid digest metadata fails closed" {
  sed -i '' 's/^ALPINE_DIGEST=.*/ALPINE_DIGEST=sha256:not-a-digest/' "$LOCK_FIXTURE"
  run runtime_alpine_load
  [ "$status" -ne 0 ]
  [[ "$output" == *"64 lowercase hexadecimal"* ]]
}

@test "runtime_alpine_resolve_home prioritizes NTFSMAC_RUNTIME_HOME_OVERRIDE" {
  export NTFSMAC_RUNTIME_HOME_OVERRIDE="/custom/override/home"
  run runtime_alpine_resolve_home
  [ "$status" -eq 0 ]
  [ "$output" = "/custom/override/home" ]
}

@test "runtime_alpine_resolve_home resolves SUDO_USER home directory when running as root" {
  local fake_home="$TEST_HOME/fakeuser"
  mkdir -p "$fake_home"
  local fake_bin="$TEST_HOME/bin"
  mkdir -p "$fake_bin"
  cat <<'EOF' > "$fake_bin/dscl"
#!/bin/bash
if [[ "$1" == "." && "$2" == "-read" && "$3" == "/Users/testuser" && "$4" == "NFSHomeDirectory" ]]; then
  echo "NFSHomeDirectory: $FAKE_USER_HOME"
  exit 0
fi
exit 1
EOF
  chmod +x "$fake_bin/dscl"

  unset NTFSMAC_RUNTIME_HOME_OVERRIDE
  PATH="$fake_bin:$PATH" NTFSMAC_TEST_EUID=0 SUDO_USER="testuser" FAKE_USER_HOME="$fake_home" run runtime_alpine_resolve_home
  [ "$status" -eq 0 ]
  [ "$output" = "$fake_home" ]
}

@test "runtime_alpine_resolve_home ignores invalid SUDO_USER characters" {
  unset NTFSMAC_RUNTIME_HOME_OVERRIDE
  HOME="$TEST_HOME" NTFSMAC_TEST_EUID=0 SUDO_USER="bad;user" run runtime_alpine_resolve_home
  [ "$status" -eq 0 ]
  [ "$output" = "$TEST_HOME" ]
}

@test "runtime_alpine_resolve_home falls back to HOME when not root" {
  unset NTFSMAC_RUNTIME_HOME_OVERRIDE
  HOME="$TEST_HOME" NTFSMAC_TEST_EUID=501 SUDO_USER="otheruser" run runtime_alpine_resolve_home
  [ "$status" -eq 0 ]
  [ "$output" = "$TEST_HOME" ]
}

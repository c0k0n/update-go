#!/usr/bin/env bash
# Sandboxed end-to-end tests for update-go.
#
# Runs the real script against a sandboxed environment — stubbed curl/sudo/
# uname, fixture go.dev JSON, and a fake install root — so no root and no
# network are required, and the host system is never touched.
#
# Two isolation modes, chosen automatically (override with
# UPDATE_GO_TESTS_MODE=ns|plain):
#   ns    — an unprivileged user namespace with /usr/local bind-mounted to a
#           sandbox (strongest; available on most Linux dev machines)
#   plain — HOME + UPDATE_GO_INSTALL_ROOT sandboxing without a namespace
#           (for environments like GitHub-hosted runners that block userns)
#
# Usage: tests/run.sh

# Test-harness idioms shellcheck would nag about: `cmd && ok || bad` is safe
# here because ok/bad always succeed, and quoted needles are meant to stay
# literal.
# shellcheck disable=SC2015,SC2016

set -u

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/update-go"
VER="go1.27.0"
PASS=0
FAIL=0

# ---------------------------------------------------------------
# Preflight: the isolation this suite relies on must be available.
# ---------------------------------------------------------------
for tool in jq sha256sum tar; do
    command -v "$tool" >/dev/null 2>&1 || { echo "tests: missing '$tool'"; exit 1; }
done

MODE="${UPDATE_GO_TESTS_MODE:-auto}"
if [[ "$MODE" == "auto" ]]; then
    if command -v unshare >/dev/null 2>&1 && unshare --user --map-root-user --mount true 2>/dev/null; then
        MODE="ns"
    else
        MODE="plain"
    fi
fi
if [[ "$MODE" == "ns" ]]; then
    command -v unshare >/dev/null 2>&1 || { echo "tests: missing 'unshare'"; exit 1; }
    unshare --user --map-root-user --mount true 2>/dev/null || { echo "tests: user namespaces unavailable"; exit 1; }
fi
echo "tests: isolation mode = $MODE"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/update-go-tests.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

say() { printf '\n=== %s ===\n' "$1"; }
ok()  { printf '  PASS: %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL+1)); }
VERBOSE="${UPDATE_GO_TESTS_VERBOSE:-0}"
show() { # echo captured output of the last run when verbose
    [[ "$VERBOSE" == 1 ]] && printf '%s\n' "$OUT" | sed 's/^/  | /'
    return 0
}

make_go_stub() { # $1 = version string to report, $2 = destination path
    local dest="$2"
    mkdir -p "$(dirname "$dest")"
    cat > "$dest" <<EOF
#!/usr/bin/env bash
case "\$1" in
  version) echo "go version $1 linux/amd64" ;;
  env) [[ "\$2" == "GOPATH" ]] && echo "\$HOME/go" ;;
esac
EOF
    chmod +x "$dest"
}

build_fixtures() {
    local sb="$1"
    rm -rf "$sb/tarball-src"
    mkdir -p "$sb/tarball-src/go/bin"
    make_go_stub "$VER" "$sb/tarball-src/go/bin/go"

    local files_json f os arch h
    files_json='{"filename":"'"${VER}"'.src.tar.gz","os":"","arch":"","kind":"source","sha256":"deadbeef"}'
    for f in "${VER}.linux-amd64.tar.gz" "${VER}.linux-386.tar.gz" \
             "${VER}.linux-armv6l.tar.gz" "${VER}.darwin-arm64.tar.gz"; do
        tar --owner=0 --group=0 -C "$sb/tarball-src" -czf "$sb/$f" go
        os="${f#"${VER}".}"; os="${os%%-*}"
        arch="${f#"${VER}.${os}-"}"; arch="${arch%.tar.gz}"
        h="$(sha256sum "$sb/$f" | awk '{print $1}')"
        files_json+=',{"filename":"'"$f"'","os":"'"$os"'","arch":"'"$arch"'","version":"'"$VER"'","sha256":"'"$h"'","kind":"archive"}'
    done

    cat > "$sb/fixtures.json" <<EOF
[
  {
    "version": "$VER",
    "stable": true,
    "files": [$files_json]
  }
]
EOF
}

make_curl_stub() {
    local sb="$1" mode="$2"
    # mode: ok | netfail-json | netfail-dl | netfail-self | badhash |
    #       badscript | badsums | badlayout
    mkdir -p "$sb/stubs"
    cat > "$sb/stubs/curl" <<EOF
#!/usr/bin/env bash
out=""
prev=""
for a in "\$@"; do
  [[ "\$prev" == "-o" ]] && out="\$a"
  prev="\$a"
done
for a in "\$@"; do
  case "\$a" in
    *mode=json)
      if [[ "$mode" == "netfail-json" ]]; then echo "curl: (7) connection refused" >&2; exit 7; fi
      cat "$sb/fixtures.json"; exit 0 ;;
    *releases/latest/download/update-go)
      if [[ "$mode" == "netfail-self" ]]; then echo "curl: (7) connection refused" >&2; exit 7; fi
      if [[ "$mode" == "badscript" ]]; then printf 'definitely not a script\n' > "\$out"; exit 0; fi
      cp "$sb/fake-release" "\$out" && exit 0 ;;
    *releases/latest/download/SHA256SUMS)
      if [[ "$mode" == "badsums" ]]; then
        printf '%s  update-go\n' "0000000000000000000000000000000000000000000000000000000000000000" > "\$out"
      else
        cp "$sb/fake-SHA256SUMS" "\$out"
      fi
      exit 0 ;;
    https://go.dev/dl/*)
      if [[ "$mode" == "netfail-dl" ]]; then echo "curl: (7) connection refused" >&2; exit 7; fi
      if [[ "$mode" == "badlayout" ]]; then cp "$sb/badlayout.tar.gz" "./\$(basename "\$a")" && exit 0; fi
      cp "$sb/\$(basename "\$a")" "./\$(basename "\$a")" && exit 0 ;;
  esac
done
echo "fake-curl: unexpected args: \$*" >&2
exit 1
EOF
    chmod +x "$sb/stubs/curl"
}

make_sudo_stub() {
    local sb="$1"
    cat > "$sb/stubs/sudo" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "-v" ]] && exit 0
exec "$@"
EOF
    chmod +x "$sb/stubs/sudo"
}

make_uname_stub() {
    local sb="$1"
    cat > "$sb/stubs/uname" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  -s) echo "${FAKE_UNAME_S:-Linux}" ;;
  -m) echo "${FAKE_UNAME_M:-x86_64}" ;;
  *) exec /usr/bin/uname "$@" ;;
esac
EOF
    chmod +x "$sb/stubs/uname"
}

fresh_sandbox() {
    local sb="$1"
    rm -rf "$sb"
    mkdir -p "$sb/home" "$sb/usr/local" "$sb/stubs"
    build_fixtures "$sb"
    # A fake "latest release" of update-go itself (version 9.9.9) + its checksums.
    sed 's/__UPDATE_GO_VERSION__/9.9.9/' "$SCRIPT" > "$sb/fake-release"
    sha256sum "$sb/fake-release" | awk '{print $1 "  update-go"}' > "$sb/fake-SHA256SUMS"
    # A tarball whose top-level directory is wrong (for the layout check).
    rm -rf "$sb/badlayout-src"
    mkdir -p "$sb/badlayout-src/notgo/bin"
    make_go_stub "$VER" "$sb/badlayout-src/notgo/bin/go"
    tar --owner=0 --group=0 -C "$sb/badlayout-src" -czf "$sb/badlayout.tar.gz" notgo
    make_curl_stub "$sb" "${2:-ok}"
    make_sudo_stub "$sb"
    make_uname_stub "$sb"
}

run_case() { # $1=sandbox ; rest = script args (stdin is passed through)
    local sb="$1"; shift
    local run="${FAKE_SCRIPT:-$SCRIPT}"
    # Both modes point UPDATE_GO_INSTALL_ROOT at the sandbox: in plain mode
    # it redirects the install, in ns mode it matches the bind mount — so
    # expectations are identical regardless of isolation mode.
    if [[ "$MODE" == "ns" ]]; then
        unshare --user --map-root-user --mount env \
            HOME="$sb/home" SHELL="${FAKE_SHELL:-/bin/zsh}" \
            FAKE_UNAME_S="${FAKE_UNAME_S:-}" FAKE_UNAME_M="${FAKE_UNAME_M:-}" \
            XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-}" \
            UPDATE_GO_INSTALL_ROOT="$sb/usr/local" \
            PATH="$sb/stubs:$sb/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
            bash -c "mount --bind '$sb/usr/local' /usr/local && exec '$run' $*" 2>&1
    else
        env -i \
            HOME="$sb/home" SHELL="${FAKE_SHELL:-/bin/zsh}" \
            FAKE_UNAME_S="${FAKE_UNAME_S:-}" FAKE_UNAME_M="${FAKE_UNAME_M:-}" \
            XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-}" \
            UPDATE_GO_INSTALL_ROOT="$sb/usr/local" \
            PATH="$sb/stubs:$sb/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
            bash -c "exec '$run' $*" 2>&1
    fi
}

assert_file_has() { # $1=file $2=needle $3=label
    if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3 (missing: $2 in $1)"; fi
}
assert_count() { # $1=file $2=needle $3=expected-count $4=label
    local n
    n="$(grep -cF -- "$2" "$1" 2>/dev/null || true)"
    if [[ "$n" == "$3" ]]; then ok "$4"; else bad "$4 (found $n, want $3)"; fi
}
assert_grep() { # $1=pattern $2=label (matches against $OUT)
    if grep -q -- "$1" <<<"$OUT"; then ok "$2"; else bad "$2"; fi
}

# ---------------------------------------------------------------
say "S1: fresh install"
SB="$ROOT/s1"; fresh_sandbox "$SB"
OUT="$(run_case "$SB")"; RC=$?
[[ $RC -eq 0 ]] && ok "exit code 0" || bad "exit code $RC"
assert_grep "Checksum verified" "checksum verified"
assert_grep "Added Go to PATH" "Go PATH line added"
assert_grep "Added GOPATH/bin to PATH" "GOPATH line added"
[[ -x "$SB/usr/local/go/bin/go" ]] && ok "installed into sandbox /usr/local/go" || bad "install missing"
assert_file_has "$SB/home/.zshrc" "export PATH=$SB/usr/local/go/bin:\$PATH" ".zshrc has Go line"
assert_file_has "$SB/home/.zshrc" 'export PATH="$PATH:$(go env GOPATH)/bin"' ".zshrc has GOPATH line"

# ---------------------------------------------------------------
say "S2: already up to date (rerun after S1)"
OUT="$(run_case "$SB")"; RC=$?
[[ $RC -eq 0 ]] && ok "exit code 0" || bad "exit code $RC"
assert_grep "already up to date" "reports up to date"
assert_count "$SB/home/.zshrc" '/usr/local/go/bin' 1 "no duplicate PATH lines"

# ---------------------------------------------------------------
say "S3: upgrade from older /usr/local/go"
SB="$ROOT/s3"; fresh_sandbox "$SB"
make_go_stub "go1.98.0" "$SB/usr/local/go/bin/go"
OUT="$(run_case "$SB")"; RC=$?
[[ $RC -eq 0 ]] && ok "exit code 0" || bad "exit code $RC"
assert_grep "Current version: go1.98.0" "shows old version"
assert_grep "Latest version: $VER" "shows new version"

# ---------------------------------------------------------------
say "S4: profile pre-seeded with official-docs PATH lines"
SB="$ROOT/s4"; fresh_sandbox "$SB"
{
    echo "# my rc"
    echo "export PATH=\$PATH:$SB/usr/local/go/bin"
    echo 'export PATH="$PATH:$HOME/go/bin"'
} > "$SB/home/.zshrc"
OUT="$(run_case "$SB")"; RC=$?
[[ $RC -eq 0 ]] && ok "exit code 0" || bad "exit code $RC"
assert_grep "already on PATH" "detects existing entry"
assert_count "$SB/home/.zshrc" '/usr/local/go/bin' 1 "no duplicate Go line"
# $HOME/go/bin is not necessarily $(go env GOPATH)/bin (GOPATH may be
# customized), so adding the canonical line here is correct behavior.
assert_count "$SB/home/.zshrc" 'export PATH="$PATH:$(go env GOPATH)/bin"' 1 "adds canonical GOPATH line"

# ---------------------------------------------------------------
say "S5: checksum mismatch aborts and leaves install untouched"
SB="$ROOT/s5"; fresh_sandbox "$SB" badhash
jq --arg f "${VER}.linux-amd64.tar.gz" \
   '(.[] | .files[] | select(.filename == $f) | .sha256) = "0000000000000000000000000000000000000000000000000000000000000000"' \
   "$SB/fixtures.json" > "$SB/fixtures.json.tmp" && mv "$SB/fixtures.json.tmp" "$SB/fixtures.json"
make_go_stub "go1.98.0" "$SB/usr/local/go/bin/go"
OUT="$(run_case "$SB")"; RC=$?
[[ $RC -ne 0 ]] && ok "non-zero exit" || bad "should have failed"
assert_grep "Checksum verification failed" "clear failure message"
[[ -x "$SB/usr/local/go/bin/go" ]] && ok "old install untouched" || bad "old install destroyed!"
grep -q "go1.98.0" <("$SB/usr/local/go/bin/go" version) && ok "old version still present" || bad "old version gone"

# ---------------------------------------------------------------
say "S6: release-info fetch failure"
SB="$ROOT/s6"; fresh_sandbox "$SB" netfail-json
OUT="$(run_case "$SB")"; RC=$?
[[ $RC -ne 0 ]] && ok "non-zero exit" || bad "should have failed"
assert_grep "Could not reach go.dev" "friendly error"

# ---------------------------------------------------------------
say "S7: tarball download failure"
SB="$ROOT/s7"; fresh_sandbox "$SB" netfail-dl
OUT="$(run_case "$SB")"; RC=$?
[[ $RC -ne 0 ]] && ok "non-zero exit" || bad "should have failed"
assert_grep "Download failed" "friendly error"

# ---------------------------------------------------------------
say "S8: --force on up-to-date install"
SB="$ROOT/s8"; fresh_sandbox "$SB"
make_go_stub "$VER" "$SB/usr/local/go/bin/go"
OUT="$(run_case "$SB" --force)"; RC=$?
[[ $RC -eq 0 ]] && ok "exit code 0" || bad "exit code $RC"
assert_grep "Installation complete" "reinstalled with --force"
assert_count "$SB/home/.zshrc" '/usr/local/go/bin' 1 "PATH not duplicated"

# ---------------------------------------------------------------
say "S9: i686 maps to linux-386"
SB="$ROOT/s9"; fresh_sandbox "$SB"
OUT="$(FAKE_UNAME_M=i686 run_case "$SB")"; RC=$?
assert_grep "Downloading ${VER}.linux-386.tar.gz" "downloads 386 tarball"
[[ $RC -eq 0 ]] && ok "exit code 0" || bad "exit code $RC"

# ---------------------------------------------------------------
say "S10: armv7l maps to linux-armv6l"
SB="$ROOT/s10"; fresh_sandbox "$SB"
OUT="$(FAKE_UNAME_M=armv7l run_case "$SB")"; RC=$?
assert_grep "Downloading ${VER}.linux-armv6l.tar.gz" "downloads armv6l tarball"
[[ $RC -eq 0 ]] && ok "exit code 0" || bad "exit code $RC"

# ---------------------------------------------------------------
say "S11: Darwin/arm64 downloads darwin tarball"
SB="$ROOT/s11"; fresh_sandbox "$SB"
OUT="$(FAKE_UNAME_S=Darwin FAKE_UNAME_M=arm64 run_case "$SB")"; RC=$?
assert_grep "Downloading ${VER}.darwin-arm64.tar.gz" "downloads darwin tarball"
[[ $RC -eq 0 ]] && ok "exit code 0" || bad "exit code $RC"
assert_file_has "$SB/home/.zshrc" "export PATH=$SB/usr/local/go/bin:\$PATH" ".zshrc has Go line"

# ---------------------------------------------------------------
say "S12: unsupported architecture exits cleanly"
SB="$ROOT/s12"; fresh_sandbox "$SB"
OUT="$(FAKE_UNAME_M=sparc64 run_case "$SB")"; RC=$?
[[ $RC -ne 0 ]] && ok "non-zero exit" || bad "should have failed"
assert_grep "Unsupported architecture: sparc64" "names the arch"

# ---------------------------------------------------------------
say "S13: unsupported OS exits cleanly"
SB="$ROOT/s13"; fresh_sandbox "$SB"
OUT="$(FAKE_UNAME_S=FreeBSD run_case "$SB")"; RC=$?
[[ $RC -ne 0 ]] && ok "non-zero exit" || bad "should have failed"
assert_grep "supports Linux and macOS only" "friendly message"

# ---------------------------------------------------------------
say "S14: fish gets official fish_add_path lines"
SB="$ROOT/s14"; fresh_sandbox "$SB"
OUT="$(FAKE_SHELL=/bin/fish run_case "$SB")"; RC=$?
show
[[ $RC -eq 0 ]] && ok "exit code 0" || bad "exit code $RC"
assert_file_has "$SB/home/.config/fish/config.fish" "fish_add_path $SB/usr/local/go/bin" "config.fish has fish_add_path Go line"
assert_file_has "$SB/home/.config/fish/config.fish" 'fish_add_path "$(go env GOPATH)/bin"' "config.fish has fish_add_path GOPATH line"

# ---------------------------------------------------------------
say "S15: fish honors XDG_CONFIG_HOME"
SB="$ROOT/s15"; fresh_sandbox "$SB"
OUT="$(XDG_CONFIG_HOME=$SB/home/xdg FAKE_SHELL=/bin/fish run_case "$SB")"; RC=$?
[[ $RC -eq 0 ]] && ok "exit code 0" || bad "exit code $RC"
[[ ! -e "$SB/home/.config/fish/config.fish" ]] && ok "default location untouched" || bad "wrote default location despite XDG override"
assert_file_has "$SB/home/xdg/fish/config.fish" "fish_add_path $SB/usr/local/go/bin" "XDG config.fish has Go line"

# ---------------------------------------------------------------
say "S16: --version on unstamped copy"
SB="$ROOT/s16"; fresh_sandbox "$SB"
OUT="$(run_case "$SB" --version)"; RC=$?
if [[ $RC -eq 0 && "$OUT" == "update-go dev" ]]; then ok "reports 'update-go dev'"; else bad "got: $OUT"; fi

# ---------------------------------------------------------------
say "S17: --version with workflow-stamped version"
SB="$ROOT/s17"; fresh_sandbox "$SB"
sed -i 's/__UPDATE_GO_VERSION__/TESTSTAMP/' "$SCRIPT"
OUT="$(run_case "$SB" --version)"; RC=$?
sed -i 's/VERSION="TESTSTAMP"/VERSION="__UPDATE_GO_VERSION__"/' "$SCRIPT"
if [[ $RC -eq 0 && "$OUT" == "update-go TESTSTAMP" ]]; then ok "reports stamped version"; else bad "got: $OUT"; fi

# ---------------------------------------------------------------
say "S18: --help output"
SB="$ROOT/s18"; fresh_sandbox "$SB"
OUT="$(run_case "$SB" --help)"; RC=$?
[[ $RC -eq 0 ]] && ok "exit code 0" || bad "exit code $RC"
for needle in "--force" "--check" "--update" "--uninstall" "--version" "--help" \
              "SHA-256" "/usr/local/go" "\$GOPATH/bin" "bash, zsh, or fish" \
              "github.com/c0k0n/update-go" "1.25.4"; do
    grep -q -- "$needle" <<<"$OUT" && ok "mentions $needle" || bad "missing: $needle"
done

# ---------------------------------------------------------------
say "S19: unknown option handled gracefully"
SB="$ROOT/s19"; fresh_sandbox "$SB"
OUT="$(run_case "$SB" --bogus)"; RC=$?
[[ $RC -ne 0 ]] && ok "non-zero exit" || bad "should have failed"
assert_grep "Unknown option: --bogus" "names the bad option"
assert_grep "Usage:" "shows help alongside error"

# ---------------------------------------------------------------
say "S20: --update installs a newer update-go"
SB="$ROOT/s20"; fresh_sandbox "$SB"
mkdir -p "$SB/bin"
sed 's/__UPDATE_GO_VERSION__/1.0.0/' "$SCRIPT" > "$SB/bin/update-go"
chmod +x "$SB/bin/update-go"
OUT="$(FAKE_SCRIPT="$SB/bin/update-go" run_case "$SB" --update)"; RC=$?
[[ $RC -eq 0 ]] && ok "exit code 0" || bad "exit code $RC"
assert_grep "Updating update-go: 1.0.0 -> 9.9.9" "shows old -> new versions"
assert_grep "Checksum verified" "verifies SHA256SUMS"
grep -q 'VERSION="9.9.9"' "$SB/bin/update-go" && ok "copy replaced with 9.9.9" || bad "copy not replaced"
[[ -x "$SB/bin/update-go" ]] && ok "still executable" || bad "lost executable bit"

# ---------------------------------------------------------------
say "S21: --update is a no-op when current"
SB="$ROOT/s21"; fresh_sandbox "$SB"
mkdir -p "$SB/bin"
sed 's/__UPDATE_GO_VERSION__/9.9.9/' "$SCRIPT" > "$SB/bin/update-go"
chmod +x "$SB/bin/update-go"
cp "$SB/bin/update-go" "$SB/bin/before"
OUT="$(FAKE_SCRIPT="$SB/bin/update-go" run_case "$SB" --update)"; RC=$?
[[ $RC -eq 0 ]] && ok "exit code 0" || bad "exit code $RC"
assert_grep "already up to date (9.9.9)" "reports up to date"
cmp -s "$SB/bin/update-go" "$SB/bin/before" && ok "file untouched" || bad "file was modified"

# ---------------------------------------------------------------
say "S22: corrupt download -> friendly abort, original untouched"
SB="$ROOT/s22"; fresh_sandbox "$SB" badscript
mkdir -p "$SB/bin"
sed 's/__UPDATE_GO_VERSION__/1.0.0/' "$SCRIPT" > "$SB/bin/update-go"
chmod +x "$SB/bin/update-go"
OUT="$(FAKE_SCRIPT="$SB/bin/update-go" run_case "$SB" --update)"; RC=$?
[[ $RC -ne 0 ]] && ok "non-zero exit" || bad "should have failed"
assert_grep "didn't look like a working update-go" "friendly failure message"
grep -q 'VERSION="1.0.0"' "$SB/bin/update-go" && ok "original copy untouched" || bad "original copy damaged"

# ---------------------------------------------------------------
say "S23: --check when up to date changes nothing"
SB="$ROOT/s23"; fresh_sandbox "$SB"
make_go_stub "$VER" "$SB/usr/local/go/bin/go"
OUT="$(run_case "$SB" --check)"; RC=$?
[[ $RC -eq 0 ]] && ok "exit code 0" || bad "exit code $RC"
assert_grep "Status           : up to date" "reports up to date"
assert_grep "Dry run — nothing was changed" "says it's a dry run"
[[ ! -e "$SB/home/.zshrc" ]] && ok "profile untouched" || bad "profile was created"

# ---------------------------------------------------------------
say "S24: --check when update available reports, doesn't touch"
SB="$ROOT/s24"; fresh_sandbox "$SB"
make_go_stub "go1.98.0" "$SB/usr/local/go/bin/go"
OUT="$(run_case "$SB" --check)"; RC=$?
[[ $RC -eq 0 ]] && ok "exit code 0" || bad "exit code $RC"
assert_grep "Status           : update available" "reports update available"
assert_grep "Would download   : ${VER}.linux-amd64.tar.gz" "names the tarball"
assert_grep "Installed        : go1.98.0" "shows installed version"
[[ ! -e "$SB/home/.zshrc" ]] && ok "profile untouched" || bad "profile was created"
grep -q "go1.98.0" <("$SB/usr/local/go/bin/go" version) && ok "install untouched" || bad "install was modified"

# ---------------------------------------------------------------
say "S25: specific version installs; unknown version fails kindly"
SB="$ROOT/s25"; fresh_sandbox "$SB"
OUT="$(run_case "$SB" 1.27.0)"; RC=$?
[[ $RC -eq 0 ]] && ok "exit code 0" || bad "exit code $RC"
assert_grep "Requested version: $VER" "shows requested version"
[[ -x "$SB/usr/local/go/bin/go" ]] && ok "installed" || bad "not installed"
SB="$ROOT/s25b"; fresh_sandbox "$SB"
OUT="$(run_case "$SB" 9.9.9)"; RC=$?
[[ $RC -ne 0 ]] && ok "non-zero exit for unknown version" || bad "should have failed"
assert_grep "go9.9.9 wasn't found among the stable releases" "friendly not-found message"

# ---------------------------------------------------------------
say "S26: --uninstall removes Go and its PATH lines after confirmation"
SB="$ROOT/s26"; fresh_sandbox "$SB"
make_go_stub "$VER" "$SB/usr/local/go/bin/go"
{
    echo "# my rc"
    echo "export PATH=$SB/usr/local/go/bin:\$PATH"
    echo 'export PATH="$PATH:$(go env GOPATH)/bin"'
    echo "keep me"
} > "$SB/home/.zshrc"
OUT="$(echo y | run_case "$SB" --uninstall)"; RC=$?
[[ $RC -eq 0 ]] && ok "exit code 0" || bad "exit code $RC"
[[ ! -e "$SB/usr/local/go" ]] && ok "/usr/local/go removed" || bad "/usr/local/go still present"
assert_count "$SB/home/.zshrc" '/usr/local/go/bin' 0 "PATH lines removed"
grep -q "keep me" "$SB/home/.zshrc" && ok "unrelated lines preserved" || bad "clobbered unrelated lines"
assert_grep "Go has been uninstalled" "confirms uninstall"
# Declining changes nothing.
SB="$ROOT/s26b"; fresh_sandbox "$SB"
make_go_stub "$VER" "$SB/usr/local/go/bin/go"
echo 'export PATH=/usr/local/go/bin:$PATH' > "$SB/home/.zshrc"
OUT="$(echo n | run_case "$SB" --uninstall)"; RC=$?
[[ $RC -eq 0 ]] && ok "decline exits 0" || bad "decline exit code $RC"
assert_grep "Aborted — nothing was changed" "respects decline"
[[ -e "$SB/usr/local/go" ]] && ok "install kept on decline" || bad "removed despite decline"

# ---------------------------------------------------------------
say "S27: lockfile blocks a second mutating run"
SB="$ROOT/s27"; fresh_sandbox "$SB"
mkdir -p "${TMPDIR:-/tmp}/update-go.lock"
OUT="$(run_case "$SB")"; RC=$?
rmdir "${TMPDIR:-/tmp}/update-go.lock"
[[ $RC -ne 0 ]] && ok "non-zero exit" || bad "should have failed"
assert_grep "Another update-go appears to be running" "explains the lock"
[[ ! -e "$SB/home/.zshrc" ]] && ok "nothing was done" || bad "ran despite lock"

# ---------------------------------------------------------------
say "S28: --update aborts on SHA256SUMS mismatch"
SB="$ROOT/s28"; fresh_sandbox "$SB" badsums
mkdir -p "$SB/bin"
sed 's/__UPDATE_GO_VERSION__/1.0.0/' "$SCRIPT" > "$SB/bin/update-go"
chmod +x "$SB/bin/update-go"
OUT="$(FAKE_SCRIPT="$SB/bin/update-go" run_case "$SB" --update)"; RC=$?
[[ $RC -ne 0 ]] && ok "non-zero exit" || bad "should have failed"
assert_grep "Checksum verification failed for the downloaded update-go" "names the failure"
grep -q 'VERSION="1.0.0"' "$SB/bin/update-go" && ok "original copy untouched" || bad "original copy damaged"

# ---------------------------------------------------------------
say "S29: --update survives a download failure"
SB="$ROOT/s29"; fresh_sandbox "$SB" netfail-self
mkdir -p "$SB/bin"
sed 's/__UPDATE_GO_VERSION__/1.0.0/' "$SCRIPT" > "$SB/bin/update-go"
chmod +x "$SB/bin/update-go"
OUT="$(FAKE_SCRIPT="$SB/bin/update-go" run_case "$SB" --update)"; RC=$?
[[ $RC -ne 0 ]] && ok "non-zero exit" || bad "should have failed"
assert_grep "Couldn't download the latest update-go from GitHub" "friendly error"
grep -q 'VERSION="1.0.0"' "$SB/bin/update-go" && ok "original copy untouched" || bad "original copy damaged"

# ---------------------------------------------------------------
say "S30: wrong archive layout aborts, install untouched"
SB="$ROOT/s30"; fresh_sandbox "$SB" badlayout
# Serve a well-checksummed tarball whose top-level directory is wrong,
# so the layout check is what catches it (checksum runs first).
NEW_HASH="$(sha256sum "$SB/badlayout.tar.gz" | awk '{print $1}')"
jq --arg f "${VER}.linux-amd64.tar.gz" --arg h "$NEW_HASH" \
   '(.[] | .files[] | select(.filename == $f) | .sha256) = $h' \
   "$SB/fixtures.json" > "$SB/fixtures.json.tmp" && mv "$SB/fixtures.json.tmp" "$SB/fixtures.json"
make_go_stub "go1.98.0" "$SB/usr/local/go/bin/go"
OUT="$(run_case "$SB")"; RC=$?
[[ $RC -ne 0 ]] && ok "non-zero exit" || bad "should have failed"
assert_grep "Unexpected archive layout (top-level 'notgo', expected 'go')" "names the problem"
assert_grep "Nothing was changed" "promises no changes"
grep -q "go1.98.0" <("$SB/usr/local/go/bin/go" version) && ok "old install untouched" || bad "old install damaged"

# ---------------------------------------------------------------
say "S31: --uninstall when Go isn't installed"
SB="$ROOT/s31"; fresh_sandbox "$SB"
printf '# my rc\nkeep me\n' > "$SB/home/.zshrc"
OUT="$(echo y | run_case "$SB" --uninstall)"; RC=$?
[[ $RC -eq 0 ]] && ok "exit code 0" || bad "exit code $RC"
assert_grep "isn't present — skipping" "skips missing install gracefully"
assert_grep "No update-go PATH lines found" "reports nothing to clean"
grep -q "keep me" "$SB/home/.zshrc" && ok "profile untouched" || bad "profile modified"

# ---------------------------------------------------------------
say "S32: extra positional argument rejected"
SB="$ROOT/s32"; fresh_sandbox "$SB"
OUT="$(run_case "$SB" 1.27.0 1.26.0)"; RC=$?
[[ $RC -ne 0 ]] && ok "non-zero exit" || bad "should have failed"
assert_grep "Unexpected extra argument: 1.26.0" "names the extra argument"

# ---------------------------------------------------------------
say "S33: malformed version string rejected"
SB="$ROOT/s33"; fresh_sandbox "$SB"
OUT="$(run_case "$SB" abc123)"; RC=$?
[[ $RC -ne 0 ]] && ok "non-zero exit" || bad "should have failed"
assert_grep "'goabc123' doesn't look like a Go version" "explains the problem"

# ---------------------------------------------------------------
say "S34: --check runs even while another copy holds the lock"
SB="$ROOT/s34"; fresh_sandbox "$SB"
make_go_stub "$VER" "$SB/usr/local/go/bin/go"
mkdir -p "${TMPDIR:-/tmp}/update-go.lock"
OUT="$(run_case "$SB" --check)"; RC=$?
rmdir "${TMPDIR:-/tmp}/update-go.lock"
[[ $RC -eq 0 ]] && ok "exit code 0 (lock skipped for read-only)" || bad "exit code $RC"
assert_grep "Status           : up to date" "still reports status"

# ---------------------------------------------------------------
echo
echo "=============================================="
echo "Results: $PASS passed, $FAIL failed"
exit $(( FAIL > 0 ))

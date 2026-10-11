#!/bin/bash
#
# sc2fix.sh - local macOS workaround for the StarCraft II 4.10 (Base75689) startup crash:
#   libc++abi: __cxa_guard_acquire detected recursive initialization
#
# Moves Versions/<Base>/SC2.app/Contents/MacOS/SC2 to SC2.real and puts a small wrapper in
# its place that injects sc2fix.dylib (built into the same folder). Anything that launches SC2
# by its normal path - python-sc2, sc2-kiss, double-clicked replays - picks up the fix.
# Nothing in your bot changes, so ladder runs are unaffected.
#
# Usage:
#   sc2fix.sh install        build the shim and install the wrapper (safe to re-run)
#   sc2fix.sh status         report whether the fix is installed and intact
#   sc2fix.sh test           launch SC2 in API mode and check that it starts listening
#   sc2fix.sh uninstall      restore the original binary and remove the shim
#   sc2fix.sh replay FILE    open a replay through the normal Blizzard path
#
# Environment:
#   SC2PATH       StarCraft II folder (default: /Applications/StarCraft II)
#   SC2FIX_BASE   version folder to patch (default: Base75689)
#
# install needs the Xcode Command Line Tools (xcode-select --install).
# A Battle.net update or "Scan and Repair" may restore the original binary; `status` will
# report that, and running `install` again re-applies the fix.

set -euo pipefail

SC2FIX_VERSION=1
SC2_ROOT="${SC2PATH:-/Applications/StarCraft II}"
SC2_ROOT="${SC2_ROOT%/}"
BASE="${SC2FIX_BASE:-Base75689}"
DATA_VERSION_75689="B89B5D6FA7CBF6452E721311BFBC6CB2"
MARKER="# sc2fix-wrapper"

MACOS_DIR="$SC2_ROOT/Versions/$BASE/SC2.app/Contents/MacOS"
EXE="$MACOS_DIR/SC2"
REAL="$MACOS_DIR/SC2.real"
DYLIB="$MACOS_DIR/sc2fix.dylib"
WORK=""

die()  { echo "sc2fix: $*" >&2; exit 1; }
info() { echo "sc2fix: $*"; }

usage() {
  cat <<EOF
Usage: $0 <command>

  install        build the shim and install the wrapper (safe to re-run)
  status         report whether the fix is installed and intact
  test           launch SC2 in API mode and check that it starts listening
  uninstall      restore the original binary and remove the shim
  replay FILE    open a replay through the normal Blizzard path
                 (if SC2 asks you to log in, start it from the Battle.net app first)

Environment:
  SC2PATH        StarCraft II folder (now: $SC2_ROOT)
  SC2FIX_BASE    version folder to patch (now: $BASE)
EOF
}

is_macho()   { [[ -f "$1" && "$(file -b "$1")" == *Mach-O* ]]; }
is_wrapper() { [[ -f "$1" ]] && ! is_macho "$1" && grep -q -- "$MARKER" "$1"; }

require_macos()    { [[ "$(uname -s)" == Darwin ]] || die "macOS only"; }
require_base()     { [[ -d "$MACOS_DIR" ]] || die "$BASE not found at: $MACOS_DIR"; }
require_writable() { [[ -w "$MACOS_DIR" ]] || die "no write access to $MACOS_DIR - re-run with sudo"; }

make_work() {
  WORK="$(mktemp -d -t sc2fix)"
  trap 'rm -rf "$WORK"' EXIT
}

write_source() {
  cat > "$1" <<'EOF'
/*
 * sc2fix.dylib - workaround for the StarCraft II 4.10 (Base75689) macOS startup crash:
 *   libc++abi: __cxa_guard_acquire detected recursive initialization
 *
 * During C++ static initialization, SC2 sets up its allocator. That setup runs a GPU blacklist
 * check that compiles an NSRegularExpression. ICU's uregex_open allocates through global operator
 * new, which SC2 replaces with its own allocator, which re-enters the still-initializing static,
 * and libc++abi aborts.
 *
 * While any function-local static is mid-initialization on the current thread, uregex_open is made
 * to fail cleanly (U_MEMORY_ALLOCATION_ERROR). Foundation then returns nil, Objective-C messages to
 * nil return 0, and each blacklist check reads as "no match". Regexes compiled at any other time
 * are untouched. If a re-entry still happens, the call stack is printed to stderr before the abort.
 */
#include <execinfo.h>
#include <stdint.h>
#include <unistd.h>

typedef uint16_t UChar;
int  __cxa_guard_acquire(uint64_t *);
void __cxa_guard_release(uint64_t *);
void __cxa_guard_abort(uint64_t *);
void *uregex_open(const UChar *pattern, int32_t len, uint32_t flags, void *parse_error, int *status);

#define MAX_INFLIGHT 256
#define U_MEMORY_ALLOCATION_ERROR 7

static __thread uint64_t *inflight[MAX_INFLIGHT];
static __thread int depth;

static void say(const char *s) {
  const char *p = s;
  while (*p) p++;
  write(2, s, (size_t)(p - s));
}

static int fx_acquire(uint64_t *g) {
  for (int i = 0; i < depth; i++) {
    if (inflight[i] == g) {
      void *frames[128];
      say("\n[sc2fix] re-entered a static still being initialized:\n");
      backtrace_symbols_fd(frames, backtrace(frames, 128), 2);
      break;
    }
  }
  int r = __cxa_guard_acquire(g);
  if (r && depth < MAX_INFLIGHT) inflight[depth++] = g;
  return r;
}

static void fx_pop(uint64_t *g) {
  for (int i = depth - 1; i >= 0; i--) {
    if (inflight[i] == g) {
      for (int j = i; j < depth - 1; j++) inflight[j] = inflight[j + 1];
      depth--;
      return;
    }
  }
}

static void fx_release(uint64_t *g) { fx_pop(g); __cxa_guard_release(g); }
static void fx_abort(uint64_t *g)   { fx_pop(g); __cxa_guard_abort(g); }

static void *fx_regex(const UChar *p, int32_t len, uint32_t flags, void *pe, int *status) {
  if (depth == 0) return uregex_open(p, len, flags, pe, status);
  if (status && *status <= 0) *status = U_MEMORY_ALLOCATION_ERROR;
  return 0;
}

#define INTERPOSE(r, o) __attribute__((used)) static struct { const void *a, *b; } _ip_##o \
  __attribute__((section("__DATA,__interpose"))) = { (const void *)&r, (const void *)&o };
INTERPOSE(fx_acquire, __cxa_guard_acquire)
INTERPOSE(fx_release, __cxa_guard_release)
INTERPOSE(fx_abort, __cxa_guard_abort)
INTERPOSE(fx_regex, uregex_open)
EOF
}

build_dylib() {
  local out="$1"
  if ! command -v clang >/dev/null 2>&1 || ! xcode-select -p >/dev/null 2>&1; then
    die "clang not found - install the Xcode Command Line Tools: xcode-select --install"
  fi
  write_source "$WORK/sc2fix.c"
  clang -arch x86_64 -dynamiclib -O2 -Wall -mmacosx-version-min=11.0 \
    -o "$out" "$WORK/sc2fix.c" -licucore -lc++
  codesign -s - -f "$out" >/dev/null 2>&1 || true
}

write_wrapper() {
  cat > "$1" <<EOF
#!/bin/bash
$MARKER v$SC2FIX_VERSION - installed by sc2fix.sh. The original binary is SC2.real.
# Injects sc2fix.dylib (same folder) into SC2.real. To undo: sc2fix.sh uninstall
DIR="\$(cd "\$(dirname "\$0")" && pwd -P)"
export DYLD_INSERT_LIBRARIES="\$DIR/sc2fix.dylib\${DYLD_INSERT_LIBRARIES:+:\$DYLD_INSERT_LIBRARIES}"
exec -a "\$0" "\$DIR/SC2.real" "\$@"
EOF
  chmod 755 "$1"
}

cmd_install() {
  require_macos
  require_base
  require_writable

  local state
  if is_wrapper "$EXE"; then
    is_macho "$REAL" || die "wrapper found but SC2.real is missing - repair $BASE and run install again"
    state=refresh
  elif is_macho "$EXE"; then
    if [[ -e "$REAL" ]]; then state=reapply; else state=fresh; fi
  elif [[ ! -e "$EXE" ]] && is_macho "$REAL"; then
    state=rewrap
  else
    die "unexpected contents at $EXE - not touching it"
  fi

  make_work
  info "building sc2fix.dylib"
  build_dylib "$WORK/sc2fix.dylib"
  write_wrapper "$WORK/SC2"

  case "$state" in
    fresh)
      mv "$EXE" "$REAL"
      ;;
    reapply)
      info "SC2 was restored (likely by a Battle.net update or repair) - wrapping the restored binary"
      mv -f "$EXE" "$REAL"
      ;;
  esac

  cp "$WORK/sc2fix.dylib" "$DYLIB.tmp"
  mv -f "$DYLIB.tmp" "$DYLIB"
  cp "$WORK/SC2" "$EXE.tmp"
  chmod 755 "$EXE.tmp"
  mv -f "$EXE.tmp" "$EXE"

  info "installed for $BASE ($state)"
  info "verify with: $0 test"
}

cmd_status() {
  echo "SC2 folder:  $SC2_ROOT"
  echo "Version:     $BASE"
  if [[ ! -d "$MACOS_DIR" ]]; then
    echo "State:       $BASE is not present"
    return 1
  fi

  local state rc=1
  if is_wrapper "$EXE" && is_macho "$REAL" && [[ -f "$DYLIB" ]]; then
    state="installed"
    rc=0
  elif is_macho "$EXE" && [[ -e "$REAL" ]]; then
    state="reverted - Battle.net restored the original SC2; run: $0 install"
  elif is_macho "$EXE"; then
    state="not installed"
  elif is_wrapper "$EXE" && ! is_macho "$REAL"; then
    state="broken - wrapper present but SC2.real is missing"
  elif is_wrapper "$EXE"; then
    state="broken - sc2fix.dylib is missing; run: $0 install"
  elif [[ ! -e "$EXE" ]] && is_macho "$REAL"; then
    state="broken - wrapper is missing; run: $0 install"
  else
    state="unknown - unexpected file at $EXE"
  fi

  echo "State:       $state"
  if is_wrapper "$EXE"; then
    echo "Wrapper:     $(grep -m1 "$MARKER" "$EXE" | awk '{print $3}')"
  fi
  if [[ -f "$DYLIB" ]]; then
    echo "Shim:        $DYLIB ($(lipo -archs "$DYLIB" 2>/dev/null || echo 'arch unknown'))"
  fi
  return "$rc"
}

cmd_uninstall() {
  require_macos
  require_base
  require_writable

  if is_wrapper "$EXE"; then
    [[ -f "$REAL" ]] || die "wrapper found but SC2.real is missing - repair $BASE via Battle.net"
    mv -f "$REAL" "$EXE"
    info "restored the original SC2"
  elif [[ ! -e "$EXE" && -f "$REAL" ]]; then
    mv "$REAL" "$EXE"
    info "restored the original SC2"
  elif is_macho "$EXE"; then
    if [[ -e "$REAL" ]]; then
      rm -f "$REAL"
      info "SC2 had already been restored; removed the leftover SC2.real"
    else
      info "not installed"
    fi
  else
    die "unexpected contents at $EXE - not touching it"
  fi
  rm -f "$DYLIB" "$DYLIB.tmp" "$EXE.tmp"
}

cmd_test() {
  require_macos
  require_base
  is_wrapper "$EXE" || die "not installed - run: $0 install"
  make_work

  local port=$(( 20000 + RANDOM % 10000 ))
  local args=(-listen 127.0.0.1 -port "$port" -displayMode 0 -dataDir "$SC2_ROOT/" -tempDir "$WORK/" -verbose)
  if [[ "$BASE" == Base75689 ]]; then
    args+=(-dataVersion "$DATA_VERSION_75689")
  fi

  info "launching $BASE on port $port (a game window may open briefly)"
  "$EXE" "${args[@]}" > "$WORK/sc2.log" 2>&1 &
  local pid=$! rc=0 result=timeout i
  # stderr is silenced for the whole loop so bash's own "Abort trap" job notice doesn't clutter
  # the output; SC2's real output is in sc2.log and is shown below on failure.
  {
    for (( i = 0; i < 90; i++ )); do
      if ! kill -0 "$pid"; then
        wait "$pid" || rc=$?
        result=exited
        break
      fi
      if nc -z 127.0.0.1 "$port" >/dev/null; then
        result=listening
        break
      fi
      sleep 1
    done
    if [[ "$result" != exited ]]; then
      kill "$pid" || true
      wait "$pid" || true
    fi
  } 2>/dev/null

  case "$result" in
    listening)
      info "PASS: SC2 is up and listening on port $port"
      ;;
    exited)
      echo "--- last SC2 output ---"
      tail -n 40 "$WORK/sc2.log"
      die "FAIL: SC2 exited with status $rc before it started listening"
      ;;
    *)
      die "FAIL: SC2 did not start listening within 90 seconds"
      ;;
  esac
}

cmd_replay() {
  require_macos
  [[ $# -eq 1 ]] || die "usage: $0 replay FILE.SC2Replay"
  local f="$1"
  [[ -f "$f" ]] || die "no such file: $f"

  shopt -s nocasematch
  if [[ "$f" != *.sc2replay ]]; then
    info "warning: $f does not end in .SC2Replay"
  fi
  shopt -u nocasematch

  if ! is_wrapper "$EXE"; then
    info "warning: the fix is not installed for $BASE - 4.10 replays will crash (run: $0 install)"
  fi
  open "$f"
}

cmd="${1:-help}"
if [[ $# -gt 0 ]]; then shift; fi
case "$cmd" in
  install|status|uninstall|test|replay) "cmd_$cmd" "$@" ;;
  help|-h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac

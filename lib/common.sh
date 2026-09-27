# lib/common.sh — logging, error handling, stage bookkeeping. Sourced by install.sh.
# shellcheck shell=bash

# ---- output -----------------------------------------------------------------
if [[ -t 2 ]]; then
  _c_info=$'\033[1;34m'; _c_ok=$'\033[1;32m'; _c_warn=$'\033[1;33m'; _c_err=$'\033[1;31m'; _c_off=$'\033[0m'
else
  _c_info=""; _c_ok=""; _c_warn=""; _c_err=""; _c_off=""
fi
_ts() { date '+%H:%M:%S'; }
info()  { printf '%s[%s] ==> %s%s\n' "$_c_info" "$(_ts)" "$*" "$_c_off" >&2; }
ok()    { printf '%s[%s] ok  %s%s\n' "$_c_ok"   "$(_ts)" "$*" "$_c_off" >&2; }
warn()  { printf '%s[%s] WARN %s%s\n' "$_c_warn" "$(_ts)" "$*" "$_c_off" >&2; }
die()   { printf '%s[%s] ERROR %s%s\n' "$_c_err" "$(_ts)" "$*" "$_c_off" >&2; exit 1; }
verbose() { if [[ "${VERBOSE:-0}" == 1 ]]; then printf '        %s\n' "$*" >&2; fi; }

# Print the tail of a log when a stage fails, so the user never has to hunt for it.
on_error() {
  local rc=$? line=$1
  printf '%s[%s] ERROR install.sh failed (exit %s) at line %s during stage "%s"%s\n' \
    "$_c_err" "$(_ts)" "$rc" "$line" "${CURRENT_STAGE:-?}" "$_c_off" >&2
  if [[ -n "${CURRENT_LOG:-}" && -s "${CURRENT_LOG}" ]]; then
    printf '%s----- last 40 lines of %s -----%s\n' "$_c_err" "$CURRENT_LOG" "$_c_off" >&2
    tail -n 40 "$CURRENT_LOG" >&2
    printf '%s----- full log: %s -----%s\n' "$_c_err" "$CURRENT_LOG" "$_c_off" >&2
  fi
  exit "$rc"
}

# ---- helpers ----------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

# run_logged NAME cmd... : run a command with stdout+stderr appended to $LOG_DIR/NAME.log
run_logged() {
  local name=$1; shift
  CURRENT_LOG="$LOG_DIR/$name.log"
  {
    printf '\n##### %s  %s\n##### cwd: %s\n##### cmd: %s\n\n' "$(date -Is)" "$name" "$PWD" "$*"
  } >>"$CURRENT_LOG"
  if [[ "${VERBOSE:-0}" == 1 ]]; then
    "$@" 2>&1 | tee -a "$CURRENT_LOG"
    return "${PIPESTATUS[0]}"
  else
    "$@" >>"$CURRENT_LOG" 2>&1
  fi
}

sha256_of() { sha256sum "$1" | awk '{print $1}'; }

verify_sha256() {
  local file=$1 expected=$2 actual
  actual=$(sha256_of "$file")
  [[ "$actual" == "$expected" ]] || die "checksum mismatch for $file
    expected: $expected
    actual:   $actual"
}

# fetch URL DEST : download with retries, atomically (tmp file, then mv)
fetch() {
  local url=$1 dest=$2
  mkdir -p "$(dirname "$dest")"
  if have curl; then
    curl -fL --retry 3 --retry-delay 5 --connect-timeout 30 -o "$dest.part" "$url"
  elif have wget; then
    wget -q --tries=3 -O "$dest.part" "$url"
  else
    die "need curl or wget to download $url"
  fi
  mv -f "$dest.part" "$dest"
}

# version_ge A B : true if dotted version A >= B
version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]; }

# ---- Lmod without an interactive shell -------------------------------------
# `module` is a shell function that login shells get from /etc/profile.d; a script
# started with `./install.sh` does not inherit it. Drive Lmod through $LMOD_CMD instead.
init_modules() {
  if ! have_module_function; then
    local f
    for f in /etc/profile.d/modules.sh /etc/profile.d/00-modulepath.sh /usr/share/lmod/lmod/init/bash; do
      # shellcheck disable=SC1090
      if [[ -r "$f" ]]; then source "$f"; fi
    done
  fi
  LMOD_CMD=${LMOD_CMD:-/usr/share/lmod/lmod/libexec/lmod}
  [[ -x "$LMOD_CMD" ]] || die "Lmod not found (LMOD_CMD=$LMOD_CMD). Is this Forerunner 1?"
}
have_module_function() { declare -F module >/dev/null 2>&1; }
# qe_module ARGS... : like `module ARGS`, but works in scripts
qe_module() {
  local out
  out=$("$LMOD_CMD" bash "$@") || die "module $* failed"
  eval "$out"
}
# module_exists NAME : true if Lmod can load NAME right now (hierarchy-aware)
module_exists() { local out; out=$("$LMOD_CMD" bash is-avail "$1" 2>/dev/null) || return 1; eval "$out"; }

# ---- stages -----------------------------------------------------------------
# A stage runs once per configuration; STAMP_DIR/<stage> records completion together with
# the configuration fingerprint, so changing --toolchain/--prefix/... re-runs what matters.
stage_done() { [[ -f "$STAMP_DIR/$1" && "$(cat "$STAMP_DIR/$1")" == "$CONFIG_FINGERPRINT" ]]; }
stage_mark() { mkdir -p "$STAMP_DIR"; printf '%s\n' "$CONFIG_FINGERPRINT" >"$STAMP_DIR/$1"; }
stage_clear() { rm -f "$STAMP_DIR/$1"; }
# run_stage NAME FUNCTION : skip if already done for this fingerprint
run_stage() {
  local name=$1 fn=$2
  CURRENT_STAGE=$name
  if stage_done "$name" && [[ "${FORCE_STAGES:-0}" != 1 ]]; then
    ok "stage $name: already done (use --reconfigure to redo)"
    return 0
  fi
  info "stage $name"
  local t0=$SECONDS
  "$fn"
  stage_mark "$name"
  ok "stage $name finished in $((SECONDS - t0)) s"
}

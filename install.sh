#!/usr/bin/env bash
# install.sh — reproducible, one-command Quantum ESPRESSO build for NCHC Forerunner 1 (創進一號).
#
#   git clone https://github.com/smartalan91/qe-f1-install.git
#   ./qe-f1-install/install.sh
#
# Works for any user from any directory. No containers, no Spack: only the site's Lmod
# modules plus upstream sources pinned by version and checksum in versions.lock.
# Run with -h for options.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
trap 'on_error $LINENO' ERR
# shellcheck source=versions.lock
source "$SCRIPT_DIR/versions.lock"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Build and install Quantum ESPRESSO $QE_VERSION from source on Forerunner 1.

  --prefix DIR         install location          (default: \$HOME/opt/qe/$QE_VERSION-<toolchain>)
  --toolchain NAME     intel | gnu               (default: intel)
  --compiler NAME      intel only: ifort | ifx   (default: ifort; ifx 2024.0 has an ICE on QE 7.6)
  --openmp on|off      hybrid MPI+OpenMP build   (default: off, pure MPI)
  --jobs N             parallel build jobs       (default: 16)
  --build-root DIR     scratch for sources/build (default: /work1/\$USER/.qe-f1-build, else ~/.cache)
  --cache-dir DIR      download cache            (default: ~/.cache/qe-f1-install)
  --no-test            skip the post-install smoke test on the login node
  --slurm-test ACCT    additionally run the smoke test as a SLURM job charged to ACCT
  --reconfigure        redo configure/build/install even if stamps say they are done
  --clean              delete the build directory first (downloads are kept)
  --force-host         allow running on a machine that does not look like Forerunner 1
  --dry-run            print the plan and exit
  --verbose            stream build output to the terminal as well as the logs
  -h, --help           this help

Environment overrides: QE_PREFIX, QE_BUILD_ROOT, QE_CACHE_DIR, QE_JOBS.
Every external input (URLs, checksums, submodule commits, module names) is in versions.lock.
EOF
}

# ---- options ----------------------------------------------------------------
TOOLCHAIN=intel; COMPILER=""; OPENMP=off
JOBS=${QE_JOBS:-16}
PREFIX=${QE_PREFIX:-}; BUILD_ROOT=${QE_BUILD_ROOT:-}; CACHE_DIR=${QE_CACHE_DIR:-$HOME/.cache/qe-f1-install}
RUN_TEST=1; SLURM_ACCOUNT=""; FORCE_HOST=0; FORCE_STAGES=0; CLEAN=0; DRY_RUN=0; VERBOSE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)      PREFIX=$2; shift 2 ;;
    --toolchain)   TOOLCHAIN=$2; shift 2 ;;
    --compiler)    COMPILER=$2; shift 2 ;;
    --openmp)      OPENMP=$2; shift 2 ;;
    --jobs)        JOBS=$2; shift 2 ;;
    --build-root)  BUILD_ROOT=$2; shift 2 ;;
    --cache-dir)   CACHE_DIR=$2; shift 2 ;;
    --no-test)     RUN_TEST=0; shift ;;
    --slurm-test)  SLURM_ACCOUNT=$2; shift 2 ;;
    --reconfigure) FORCE_STAGES=1; shift ;;
    --clean)       CLEAN=1; shift ;;
    --force-host)  FORCE_HOST=1; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --verbose)     VERBOSE=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done
case "$TOOLCHAIN" in intel|gnu) ;; *) die "--toolchain must be intel or gnu" ;; esac
case "$OPENMP" in on|off) ;; *) die "--openmp must be on or off" ;; esac
[[ "$JOBS" =~ ^[0-9]+$ && "$JOBS" -ge 1 ]] || die "--jobs must be a positive integer"

# ---- derived paths -----------------------------------------------------------
PREFIX=${PREFIX:-$HOME/opt/qe/$QE_VERSION-$TOOLCHAIN}
PREFIX=$(readlink -m "$PREFIX")
if [[ -z "$BUILD_ROOT" ]]; then
  if [[ -d "/work1/$USER" && -w "/work1/$USER" ]]; then BUILD_ROOT="/work1/$USER/.qe-f1-build"; else BUILD_ROOT="$HOME/.cache/qe-f1-install/build"; fi
fi
BUILD_ROOT=$(readlink -m "$BUILD_ROOT"); CACHE_DIR=$(readlink -m "$CACHE_DIR")
BUILD_DIR="$BUILD_ROOT/qe-$QE_VERSION-$TOOLCHAIN"
SRC_DIR="$BUILD_DIR/src"; BLD_DIR="$BUILD_DIR/build"; LOG_DIR="$BUILD_DIR/logs"; STAMP_DIR="$BUILD_DIR/.stamps"
TARBALL="$CACHE_DIR/downloads/$(basename "$QE_TARBALL_URL")"
[[ "$PREFIX" == "$BUILD_DIR"* ]] && die "--prefix must not be inside the build directory"

# The toolchain file resolves the default compiler at load time, so the fingerprint below
# reflects what will actually be used (an unspecified --compiler must not alias a specified one).
# shellcheck source=lib/toolchain_intel.sh
source "$SCRIPT_DIR/lib/toolchain_$TOOLCHAIN.sh"
CONFIG_FINGERPRINT=$(printf '%s' "$QE_VERSION|$TOOLCHAIN|$COMPILER|$OPENMP|$PREFIX" | sha256sum | cut -c1-12)

# ---- stages -----------------------------------------------------------------
stage_preflight() {
  init_modules
  local host; host=$(hostname -s)
  if [[ ! "$host" =~ ^(ilgn|xdata|icpn|f1-) ]] && [[ "$FORCE_HOST" != 1 ]]; then
    die "host '$host' does not look like Forerunner 1 (ilgn*/icpn*). Use --force-host to override."
  fi
  have cmake || die "cmake not found"
  local cmv; cmv=$(cmake --version | awk 'NR==1{print $3}')
  version_ge "$cmv" 3.20 || die "cmake >= 3.20 required (found $cmv)"
  have git || die "git not found"
  have sha256sum || die "sha256sum not found"
  have make || die "make not found"
  have curl || have wget || die "curl or wget required"

  mkdir -p "$BUILD_DIR" "$LOG_DIR" "$CACHE_DIR/downloads" || die "cannot create $BUILD_DIR / $CACHE_DIR"
  mkdir -p "$(dirname "$PREFIX")"
  [[ -w "$(dirname "$PREFIX")" ]] || die "cannot write to $(dirname "$PREFIX")"
  local free_kb; free_kb=$(df -Pk "$BUILD_ROOT" | awk 'NR==2{print $4}')
  (( free_kb > 4*1024*1024 )) || die "need at least 4 GB free in $BUILD_ROOT (have $((free_kb/1024)) MB)"

  toolchain_setup           # loads modules, sets FC/CC/CXX, CMAKE_TOOLCHAIN_ARGS, template variables
  cat >&2 <<EOF
        QE version   : $QE_VERSION  ($QE_TARBALL_URL)
        toolchain    : $TOOLCHAIN — $TOOLCHAIN_DESC
        OpenMP       : $OPENMP
        prefix       : $PREFIX
        build dir    : $BUILD_DIR
        logs         : $LOG_DIR
        jobs         : $JOBS
        fingerprint  : $CONFIG_FINGERPRINT
EOF
}

stage_fetch() {
  if [[ -f "$TARBALL" ]] && [[ "$(sha256_of "$TARBALL")" == "$QE_TARBALL_SHA256" ]]; then
    ok "tarball cached: $TARBALL"
  else
    info "downloading $QE_TARBALL_URL"
    fetch "$QE_TARBALL_URL" "$TARBALL"
    verify_sha256 "$TARBALL" "$QE_TARBALL_SHA256"
    ok "sha256 verified"
  fi
  if [[ ! -f "$SRC_DIR/.extracted" ]]; then
    rm -rf "$SRC_DIR"; mkdir -p "$SRC_DIR"
    tar -xzf "$TARBALL" -C "$SRC_DIR" --strip-components=1
    [[ -f "$SRC_DIR/CMakeLists.txt" ]] || die "unexpected tarball layout (no CMakeLists.txt after extraction)"
    touch "$SRC_DIR/.extracted"
  fi
  # Submodules: the archive ships empty directories; fetch the exact recorded commits.
  local name hash rec url dir
  for name in $QE_SUBMODULES; do
    hash=$(eval "printf '%s' \"\$QE_SUBMODULE_$name\"")
    rec=$(awk -v n="$name" '$2==n{print $1}' "$SRC_DIR/external/submodule_commit_hash_records")
    [[ "$rec" == "$hash" ]] || die "versions.lock pins $name at $hash but the tarball records $rec — update versions.lock"
    dir="$SRC_DIR/external/$name"
    if [[ -d "$dir/.git" ]] && [[ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" == "$hash" ]]; then
      verbose "submodule $name already at $hash"; continue
    fi
    url=$(git -C "$SRC_DIR" config --file .gitmodules --get "submodule.external/$name.url")
    info "fetching submodule $name @ ${hash:0:12} from $url"
    rm -rf "$dir"; mkdir -p "$dir"
    run_logged fetch git -C "$dir" init -q
    run_logged fetch git -C "$dir" remote add origin "$url"
    run_logged fetch git -C "$dir" fetch -q --depth 1 origin "$hash"
    run_logged fetch git -C "$dir" checkout -q FETCH_HEAD
    [[ "$(git -C "$dir" rev-parse HEAD)" == "$hash" ]] || die "submodule $name is not at the pinned commit"
  done
}

stage_configure() {
  # A configure that is not current for this fingerprint (new compiler, OpenMP, prefix, ...)
  # always starts from an empty build tree; CMake does not cope with a changed compiler in place.
  rm -rf "$BLD_DIR"; stage_clear build; stage_clear install
  mkdir -p "$BLD_DIR"
  CMAKE_ARGS=(
    -S "$SRC_DIR" -B "$BLD_DIR"
    "-DCMAKE_INSTALL_PREFIX=$PREFIX"
    -DCMAKE_BUILD_TYPE=Release
    -DQE_ENABLE_MPI=ON
    "-DQE_ENABLE_OPENMP=$([[ $OPENMP == on ]] && echo ON || echo OFF)"
    -DQE_ENABLE_TEST=OFF
    -DQE_ENABLE_HDF5=OFF
    -DQE_ENABLE_LIBXC=OFF
    -DQE_ENABLE_FOX=OFF
    "${CMAKE_TOOLCHAIN_ARGS[@]}"
  )
  { printf '%q ' cmake "${CMAKE_ARGS[@]}"; echo; } >"$LOG_DIR/cmake-command.txt"
  run_logged configure cmake "${CMAKE_ARGS[@]}"
  grep -q "Configuring done" "$LOG_DIR/configure.log" || die "cmake did not finish configuring; see $LOG_DIR/configure.log"
  # Belt and braces: the build must not have fallen back to QE's internal BLAS/LAPACK/FFTW.
  grep -Eq "LAPACK_LIBRARIES|MKL" "$BLD_DIR/CMakeCache.txt" || warn "could not confirm MKL in CMakeCache.txt"
}

stage_build() {
  [[ -f "$BLD_DIR/CMakeCache.txt" ]] || { stage_clear configure; die "build dir missing, re-run to configure"; }
  run_logged build cmake --build "$BLD_DIR" --parallel "$JOBS"
  [[ -x "$BLD_DIR/bin/pw.x" ]] || die "pw.x was not built; see $LOG_DIR/build.log"
}

stage_install() {
  run_logged install cmake --install "$BLD_DIR"
  [[ -x "$PREFIX/bin/pw.x" ]] || die "install did not produce $PREFIX/bin/pw.x"
}

# Cheap and idempotent, so it runs on every invocation: updating a template or the smoke test
# in this repository must never require a rebuild.
stage_postinstall() {
  CURRENT_LOG=""   # nothing here is logged to a file; an error must not point at install.log
  local share="$PREFIX/share/qe-f1-install"
  mkdir -p "$share/smoke" "$share/pseudo" "$PREFIX/modulefiles/qe"
  # QE's bundled pseudopotential set (test/quality; use the SSSP/pslibrary for production)
  cp -r "$SRC_DIR/pseudo/." "$share/pseudo/"
  # Smoke test data + reference, and the test driver as a first-class executable
  cp "$SCRIPT_DIR/tests/smoke/si.scf.in" "$SCRIPT_DIR/tests/smoke/$SMOKE_PSEUDO_FILE" "$share/smoke/"
  verify_sha256 "$share/smoke/$SMOKE_PSEUDO_FILE" "$SMOKE_PSEUDO_SHA256"
  printf 'SMOKE_REF_ENERGY_RY=%s\nSMOKE_TOL_RY=%s\nTOOLCHAIN=%s\n' "$SMOKE_REF_ENERGY_RY" "$SMOKE_TOL_RY" "$TOOLCHAIN" >"$share/smoke/reference.env"
  install -m 0755 "$SCRIPT_DIR/tests/smoke.sh" "$PREFIX/bin/qe-smoke-test"

  # Templates -> env.sh, modulefile, example job script
  local date; date=$(date -Is)
  local omp_default=1
  render() {  # render TEMPLATE DEST
    awk -v QE_VERSION="$QE_VERSION" -v TOOLCHAIN="$TOOLCHAIN" -v TOOLCHAIN_DESC="$TOOLCHAIN_DESC" \
        -v PREFIX="$PREFIX" -v DATE="$date" -v OMP_DEFAULT="$omp_default" -v ACCOUNT="${SLURM_ACCOUNT:-YOUR_PROJECT_CODE}" \
        -v MODULE_LOAD_LINES="$MODULE_LOAD_LINES" -v MODULE_DEPENDS_LINES="$MODULE_DEPENDS_LINES" -v MPIRUN_LINE="$MPIRUN_LINE" '
      { gsub(/@QE_VERSION@/, QE_VERSION); gsub(/@TOOLCHAIN@/, TOOLCHAIN); gsub(/@TOOLCHAIN_DESC@/, TOOLCHAIN_DESC)
        gsub(/@PREFIX@/, PREFIX); gsub(/@DATE@/, DATE); gsub(/@OMP_DEFAULT@/, OMP_DEFAULT); gsub(/@ACCOUNT@/, ACCOUNT)
        if ($0 ~ /@MODULE_LOAD_LINES@/)    { print MODULE_LOAD_LINES;    next }
        if ($0 ~ /@MODULE_DEPENDS_LINES@/) { print MODULE_DEPENDS_LINES; next }
        if ($0 ~ /@MPIRUN_LINE@/)          { print MPIRUN_LINE;          next }
        print }' "$1" >"$2"
  }
  render "$SCRIPT_DIR/templates/env.sh.in"         "$PREFIX/env.sh"
  render "$SCRIPT_DIR/templates/modulefile.lua.in" "$PREFIX/modulefiles/qe/$QE_VERSION-$TOOLCHAIN.lua"
  render "$SCRIPT_DIR/templates/qe.sbatch.in"      "$share/qe.sbatch"

  # Build record: everything needed to reproduce or audit this installation
  local installer_commit; installer_commit=$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)
  local subs="" name
  for name in $QE_SUBMODULES; do subs+="$(printf '"%s": "%s", ' "$name" "$(eval "printf '%s' \"\$QE_SUBMODULE_$name\"")")"; done
  cat >"$PREFIX/BUILDINFO.json" <<EOF
{
  "package": "quantum-espresso",
  "version": "$QE_VERSION",
  "source": {"url": "$QE_TARBALL_URL", "sha256": "$QE_TARBALL_SHA256", "submodules": {${subs%, }}},
  "toolchain": "$TOOLCHAIN",
  "toolchain_desc": "$TOOLCHAIN_DESC",
  "compilers": "$(toolchain_versions)",
  "modules_loaded": "$("$LMOD_CMD" bash -t list 2>&1 >/dev/null | grep -v -i -E '^(currently|no modules)' | tr '
' ' ' | sed 's/ *$//')",
  "openmp": "$OPENMP",
  "cmake_version": "$(cmake --version | awk 'NR==1{print $3}')",
  "cmake_command": "$(sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' "$LOG_DIR/cmake-command.txt" | tr -d '\n')",
  "host": "$(hostname -f 2>/dev/null || hostname)",
  "os": "$(sed 's/"//g' /etc/redhat-release 2>/dev/null || uname -sr)",
  "built_by": "$USER",
  "built_at": "$date",
  "installer": "qe-f1-install",
  "installer_commit": "$installer_commit",
  "prefix": "$PREFIX"
}
EOF
  # Runtime sanity: no unresolved shared libraries in the main executable
  if bash -c "source '$PREFIX/env.sh' && ldd '$PREFIX/bin/pw.x'" 2>/dev/null | grep -q "not found"; then
    die "pw.x has unresolved shared libraries (ldd reports 'not found') — env.sh is incomplete"
  fi
}

stage_test() {
  info "smoke test on this node: pw.x on 2-atom Si, 4 MPI ranks"
  local out
  if out=$(env -i HOME="$HOME" USER="$USER" PATH="/usr/bin:/bin" TMPDIR="${TMPDIR:-/tmp}" \
           bash -lc "source '$PREFIX/env.sh' && qe-smoke-test --np 4" 2>&1); then
    printf '%s\n' "$out" | sed 's/^/        /' >&2
  else
    printf '%s\n' "$out" | sed 's/^/        /' >&2
    die "smoke test failed"
  fi
  if [[ -n "$SLURM_ACCOUNT" ]]; then
    info "submitting SLURM smoke test (account $SLURM_ACCOUNT, partition development, 8 ranks)"
    local jobdir="$BUILD_DIR/slurm-test" jid
    mkdir -p "$jobdir"
    cat >"$jobdir/smoke.sbatch" <<EOF
#!/bin/bash
#SBATCH --job-name=qe-smoke
#SBATCH --account=$SLURM_ACCOUNT
#SBATCH --partition=development
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=8
#SBATCH --time=00:10:00
#SBATCH --output=$jobdir/smoke-%j.out
source "$PREFIX/env.sh"
qe-smoke-test --workdir "$jobdir/work-\$SLURM_JOB_ID"
EOF
    jid=$(sbatch --parsable "$jobdir/smoke.sbatch")
    info "job $jid submitted; waiting (up to 30 min)"
    for _ in $(seq 1 180); do
      sleep 10
      squeue -h -j "$jid" 2>/dev/null | grep -q . || break
    done
    if grep -q "qe-smoke-test: PASS" "$jobdir/smoke-$jid.out" 2>/dev/null; then
      ok "SLURM smoke test passed: $jobdir/smoke-$jid.out"
    else
      die "SLURM smoke test did not pass; see $jobdir/smoke-$jid.out"
    fi
  fi
}

# ---- main -------------------------------------------------------------------
main() {
  local t0=$SECONDS
  info "qe-f1-install: Quantum ESPRESSO $QE_VERSION, toolchain $TOOLCHAIN"
  [[ "$CLEAN" == 1 ]] && { warn "removing $BUILD_DIR"; rm -rf "$BUILD_DIR"; }
  mkdir -p "$LOG_DIR"
  exec > >(tee -a "$LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log") 2>&1

  CURRENT_STAGE=preflight; stage_preflight
  if [[ "$DRY_RUN" == 1 ]]; then ok "dry run: nothing built"; exit 0; fi
  run_stage fetch     stage_fetch
  run_stage configure stage_configure
  [[ -x "$BLD_DIR/bin/pw.x" ]] || stage_clear build
  run_stage build     stage_build
  [[ -x "$PREFIX/bin/pw.x" ]] || stage_clear install
  run_stage install   stage_install
  CURRENT_STAGE=postinstall; info "stage postinstall (env.sh, modulefile, job template, smoke test, BUILDINFO.json)"; stage_postinstall
  if [[ "$RUN_TEST" == 1 ]]; then stage_clear test; run_stage test stage_test; else warn "smoke test skipped (--no-test)"; fi

  local n; n=$(find "$PREFIX/bin" -name '*.x' | wc -l)
  cat >&2 <<EOF

$(ok "Quantum ESPRESSO $QE_VERSION installed in $PREFIX  ($n executables, $(( (SECONDS - t0) / 60 )) min $(( (SECONDS - t0) % 60 )) s)")

  Use it:
    source $PREFIX/env.sh                 # or:
    module use $PREFIX/modulefiles && module load qe/$QE_VERSION-$TOOLCHAIN
    mpirun -np 4 pw.x -in your.in         # login node, small tests only
    sbatch $PREFIX/share/qe-f1-install/qe.sbatch your.in   # edit --account first

  Verify any time:   qe-smoke-test
  Build record:      $PREFIX/BUILDINFO.json
  Logs:              $LOG_DIR
EOF
}
main

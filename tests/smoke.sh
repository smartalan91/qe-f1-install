#!/usr/bin/env bash
# qe-smoke-test — prove that an installed Quantum ESPRESSO actually works.
#
# Runs pw.x on a 2-atom silicon SCF (the pw_scf/scf.in case of QE's own test-suite) in a
# scratch directory and compares the total energy with the reference value shipped with
# that QE release. Exit 0 = pass. Works on a login node (default) or inside a SLURM job.
#
#   qe-smoke-test [--np N] [--workdir DIR] [--keep]
#
# Installed by qe-f1-install as $PREFIX/bin/qe-smoke-test; the data lives in
# $PREFIX/share/qe-f1-install/smoke/. Also runnable from the repository checkout when
# QE_ROOT points at an installation.
set -Eeuo pipefail

NP=4; WORKDIR=""; KEEP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --np) NP=$2; shift 2 ;;
    --workdir) WORKDIR=$2; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

here=$(cd -- "$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
if [[ -f "$here/../share/qe-f1-install/smoke/reference.env" ]]; then
  DATA=$(cd "$here/../share/qe-f1-install/smoke" && pwd)      # installed layout
  QE_ROOT=${QE_ROOT:-$(cd "$here/.." && pwd)}
elif [[ -f "$here/smoke/si.scf.in" && -n "${QE_ROOT:-}" ]]; then
  DATA="$here/smoke"                                           # repository layout
else
  echo "cannot find smoke-test data (run the installed bin/qe-smoke-test, or set QE_ROOT)" >&2; exit 2
fi
# shellcheck disable=SC1091
[[ -f "$DATA/reference.env" ]] && source "$DATA/reference.env"
# shellcheck disable=SC1090,SC1091
[[ -f "$QE_ROOT/env.sh" ]] && source "$QE_ROOT/env.sh"
command -v pw.x >/dev/null || { echo "pw.x not in PATH (source $QE_ROOT/env.sh?)" >&2; exit 2; }

REF=${SMOKE_REF_ENERGY_RY:?reference energy missing}
TOL=${SMOKE_TOL_RY:-1.0e-4}

WORKDIR=${WORKDIR:-$(mktemp -d "${TMPDIR:-/tmp}/qe-smoke.XXXXXX")}
mkdir -p "$WORKDIR"; cp "$DATA/si.scf.in" "$DATA"/*.UPF "$WORKDIR"/
cd "$WORKDIR"

if [[ -n "${SLURM_JOB_ID:-}" ]]; then
  launch=(mpirun -np "${SLURM_NTASKS:-$NP}")
else
  # single node: shared-memory transport only (Intel MPI / Open MPI knobs, harmless for the other)
  export I_MPI_FABRICS=shm OMPI_MCA_btl=self,vader
  launch=(mpirun -np "$NP")
fi
export OMP_NUM_THREADS=${OMP_NUM_THREADS:-1}

echo "qe-smoke-test: $(command -v pw.x)"
echo "qe-smoke-test: ${launch[*]} pw.x -in si.scf.in   (workdir $WORKDIR)"
t0=$SECONDS
"${launch[@]}" pw.x -in si.scf.in >si.scf.out 2>si.scf.err || {
  echo "qe-smoke-test: FAIL — pw.x exited non-zero; see $WORKDIR/si.scf.out and si.scf.err" >&2; exit 1; }
grep -q "JOB DONE" si.scf.out || { echo "qe-smoke-test: FAIL — no 'JOB DONE' in $WORKDIR/si.scf.out" >&2; exit 1; }
E=$(awk '/^!/ {e=$(NF-1)} END {print e}' si.scf.out)
[[ -n "$E" ]] || { echo "qe-smoke-test: FAIL — total energy not found in $WORKDIR/si.scf.out" >&2; exit 1; }
nproc_used=$(awk '/Parallel version \(MPI\), running on/ {print $(NF-1); exit}' si.scf.out)

if awk -v a="$E" -v b="$REF" -v tol="$TOL" 'BEGIN { d=a-b; if (d<0) d=-d; exit !(d<=tol) }'; then
  echo "qe-smoke-test: PASS  total energy = $E Ry (reference $REF Ry, tol $TOL), ${nproc_used:-?} MPI ranks, $((SECONDS - t0)) s"
  [[ $KEEP == 1 ]] || rm -rf "$WORKDIR"
  exit 0
else
  echo "qe-smoke-test: FAIL  total energy = $E Ry differs from reference $REF Ry by more than $TOL (kept $WORKDIR)" >&2
  exit 1
fi

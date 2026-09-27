# lib/toolchain_intel.sh — Intel oneAPI toolchain on Forerunner 1 (default).
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2016  # variables here are the interface consumed by install.sh; single quotes are deliberate
#
# Compilers : ifort (classic, default) or ifx (LLVM-based) via Intel MPI wrappers
# MPI       : Intel MPI 2021.11
# Math      : MKL 2024.0 — BLAS/LAPACK, ScaLAPACK+BLACS, FFT through the native DFTI interface
# Everything comes from the single site module pinned in versions.lock (F1_INTEL_MODULE).

# Default is the classic compiler: ifx 2024.0.2 dies with an internal compiler error
# (segmentation violation) on PHonon/PH/symdynph_gq.f90 of QE 7.6 (verified 2026-09-27).
# --compiler ifx is kept for newer oneAPI releases where that bug is fixed.
COMPILER=${COMPILER:-ifort}

toolchain_setup() {
  qe_module purge
  module_exists "$F1_INTEL_MODULE" || die "module $F1_INTEL_MODULE not found on this host"
  qe_module load "$F1_INTEL_MODULE"

  local fflags=""
  case "$COMPILER" in
    ifx)   FC=mpiifx ;;
    ifort) FC=mpiifort; fflags="-diag-disable=10448" ;;   # silence the ifort deprecation remark
    *)     die "--compiler must be ifx or ifort for the intel toolchain (got '$COMPILER')" ;;
  esac
  # icc/icpc were removed from oneAPI 2024; the LLVM C/C++ compilers are the only choice.
  CC=mpiicx; CXX=mpiicpx
  local b
  for b in "$FC" "$CC" "$CXX" mpirun cmake; do
    have "$b" || die "'$b' not in PATH after loading $F1_INTEL_MODULE"
  done
  [[ -n "${MKLROOT:-}" && -d "$MKLROOT" ]] || die "MKLROOT is not set by $F1_INTEL_MODULE"

  local blas
  if [[ "$OPENMP" == on ]]; then blas=Intel10_64lp; else blas=Intel10_64lp_seq; fi

  CMAKE_TOOLCHAIN_ARGS=(
    "-DCMAKE_Fortran_COMPILER=$FC"
    "-DCMAKE_C_COMPILER=$CC"
    "-DCMAKE_CXX_COMPILER=$CXX"
    "-DBLA_VENDOR=$blas"
    "-DQE_ENABLE_SCALAPACK=ON"
    "-DQE_FFTW_VENDOR=Intel_DFTI"
  )
  [[ -n "$fflags" ]] && CMAKE_TOOLCHAIN_ARGS+=("-DCMAKE_Fortran_FLAGS=$fflags")

  # Consumed by the templates written at install time
  TOOLCHAIN_DESC="Intel oneAPI 2024.0 ($FC, Intel MPI 2021.11, MKL 2024.0 BLAS/LAPACK/ScaLAPACK/DFTI)"
  MODULE_LOAD_LINES="module purge
module load $F1_INTEL_MODULE"
  MODULE_DEPENDS_LINES="depends_on(\"$F1_INTEL_MODULE\")"
  MPIRUN_LINE='mpirun -np "${SLURM_NTASKS}" pw.x -in "$INPUT" > "${INPUT%.in}.out"'
}

# Versions, for BUILDINFO.json
toolchain_versions() {
  printf '%s | %s | %s' \
    "$("$FC" --version 2>/dev/null | head -n1)" \
    "$(mpirun --version 2>/dev/null | head -n1)" \
    "MKL $(basename "$MKLROOT")"
}

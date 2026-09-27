# lib/toolchain_gnu.sh — GNU toolchain on Forerunner 1 (alternative: --toolchain gnu).
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2016  # variables here are the interface consumed by install.sh; single quotes are deliberate
#
# Compilers : gfortran/gcc from the site gcc module
# MPI       : Open MPI from the Lmod hierarchy under that gcc
# Math      : MKL (GNU interface mkl_gf_lp64, sequential threading, BLACS for Open MPI, FFTW3 wrappers)
#             taken from the same oneAPI tree as the intel toolchain, *without* loading the
#             intel module, so Intel MPI never shadows Open MPI in PATH.

[[ -z "${COMPILER:-}" || "$COMPILER" == gfortran ]] || { echo "ERROR --compiler is only meaningful with --toolchain intel" >&2; exit 1; }
COMPILER=gfortran

toolchain_setup() {
  qe_module purge
  module_exists "$F1_GCC_MODULE" || die "module $F1_GCC_MODULE not found on this host"
  qe_module load "$F1_GCC_MODULE"
  module_exists "$F1_OPENMPI_MODULE" || die "module $F1_OPENMPI_MODULE not found under $F1_GCC_MODULE"
  qe_module load "$F1_OPENMPI_MODULE"

  FC=mpif90; CC=mpicc; CXX=mpicxx
  local b
  for b in "$FC" "$CC" "$CXX" mpirun cmake; do
    have "$b" || die "'$b' not in PATH after loading $F1_GCC_MODULE + $F1_OPENMPI_MODULE"
  done
  "$FC" --version | grep -q "GNU Fortran" || die "$FC does not wrap gfortran (module order problem?)"

  # MKL location: derive it from the pinned intel module instead of hard-coding a path.
  MKLROOT=$("$LMOD_CMD" bash show "$F1_INTEL_MODULE" 2>&1 | sed -n 's/^setenv("MKLROOT","\(.*\)")$/\1/p' | head -n1)
  [[ -n "$MKLROOT" && -d "$MKLROOT/lib/intel64" ]] || die "could not locate MKL via module $F1_INTEL_MODULE"
  export MKLROOT

  # Without the intel module there are no CMAKE_PREFIX_PATH/LIBRARY_PATH hints, and CMake's
  # FindBLAS does not locate MKL for gfortran on its own. Spell the link line out instead:
  # GNU Fortran interface (mkl_gf_lp64), sequential or GNU-OpenMP threading, BLACS for Open MPI.
  local mkllib="$MKLROOT/lib/intel64" thread blas_libs scalapack_libs
  if [[ "$OPENMP" == on ]]; then thread="$mkllib/libmkl_gnu_thread.so;-lgomp"; else thread="$mkllib/libmkl_sequential.so"; fi
  blas_libs="$mkllib/libmkl_gf_lp64.so;$thread;$mkllib/libmkl_core.so;-lpthread;-lm;-ldl"
  scalapack_libs="$mkllib/libmkl_scalapack_lp64.so;$mkllib/libmkl_blacs_openmpi_lp64.so;$blas_libs"
  local f
  for f in libmkl_gf_lp64.so libmkl_core.so libmkl_scalapack_lp64.so libmkl_blacs_openmpi_lp64.so; do
    [[ -f "$mkllib/$f" ]] || die "expected MKL library $mkllib/$f is missing"
  done

  CMAKE_TOOLCHAIN_ARGS=(
    "-DCMAKE_Fortran_COMPILER=$FC"
    "-DCMAKE_C_COMPILER=$CC"
    "-DCMAKE_CXX_COMPILER=$CXX"
    "-DBLAS_LIBRARIES=$blas_libs"
    "-DLAPACK_LIBRARIES=$blas_libs"
    "-DQE_ENABLE_SCALAPACK=ON"
    "-DSCALAPACK_LIBRARIES=$scalapack_libs"
    "-DQE_FFTW_VENDOR=Intel_FFTW3"
    "-DCMAKE_PREFIX_PATH=$MKLROOT"
    "-DCMAKE_Fortran_FLAGS=-fallow-argument-mismatch"
  )

  TOOLCHAIN_DESC="GNU ($F1_GCC_MODULE, $F1_OPENMPI_MODULE, MKL $(basename "$MKLROOT") via mkl_gf_lp64)"
  MODULE_LOAD_LINES="module purge
module load $F1_GCC_MODULE
module load $F1_OPENMPI_MODULE
export MKLROOT=\"$MKLROOT\"
export LD_LIBRARY_PATH=\"\$MKLROOT/lib/intel64\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}\""
  MODULE_DEPENDS_LINES="depends_on(\"$F1_GCC_MODULE\", \"$F1_OPENMPI_MODULE\")
setenv(\"MKLROOT\", \"$MKLROOT\")
prepend_path(\"LD_LIBRARY_PATH\", \"$MKLROOT/lib/intel64\")"
  MPIRUN_LINE='mpirun -np "${SLURM_NTASKS}" pw.x -in "$INPUT" > "${INPUT%.in}.out"'
}

toolchain_versions() {
  printf '%s | %s | %s' \
    "$("$FC" --version 2>/dev/null | head -n1)" \
    "$(mpirun --version 2>/dev/null | head -n1)" \
    "MKL $(basename "$MKLROOT")"
}

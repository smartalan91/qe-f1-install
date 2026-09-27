# qe-f1-install

Reproducible, one-command source build of **Quantum ESPRESSO 7.6** for the NCHC
**Forerunner 1 (創進一號)** supercomputer. No containers, no Spack — just the site's
Lmod modules plus upstream sources pinned by version and checksum.

## 快速開始 / Quick start

```bash
git clone https://github.com/smartalan91/qe-f1-install.git
./qe-f1-install/install.sh
```

Run it as any user, from any directory, on a Forerunner 1 login node (`f1-ilgn01.nchc.org.tw`).
About 10 minutes later you get:

```
[12:34:56] ok  Quantum ESPRESSO 7.6 installed in /home/<you>/opt/qe/7.6-intel  (57 executables, 9 min 41 s)

  Use it:
    source /home/<you>/opt/qe/7.6-intel/env.sh                 # or:
    module use /home/<you>/opt/qe/7.6-intel/modulefiles && module load qe/7.6-intel
    mpirun -np 4 pw.x -in your.in         # login node, small tests only
    sbatch /home/<you>/opt/qe/7.6-intel/share/qe-f1-install/qe.sbatch your.in
```

The installer ends by running `pw.x` on a small silicon SCF and checking the total energy
against the reference value shipped with that QE release, so "installed" means "verified".

## What you get

| Path under the prefix | Purpose |
|---|---|
| `bin/*.x` | pw.x, ph.x, pp.x, cp.x, neb.x, projwfc.x, dos.x, bands.x, wannier90.x, … (full CMake build) |
| `bin/qe-smoke-test` | re-run the verification at any time (`qe-smoke-test --np 8`) |
| `env.sh` | `source` it: loads the right modules, sets `PATH`, `ESPRESSO_PSEUDO`, `OMP_NUM_THREADS` |
| `modulefiles/qe/7.6-<toolchain>.lua` | Lmod modulefile with `depends_on` the site modules |
| `share/qe-f1-install/qe.sbatch` | ready-to-edit SLURM job script (account, partition, 56 ranks/node) |
| `share/qe-f1-install/pseudo/` | QE's bundled test pseudopotentials |
| `BUILDINFO.json` | exact source URL + sha256, submodule commits, modules, compiler versions, cmake command, host, date |

Default prefix: `~/opt/qe/7.6-intel`. Build scratch: `/work1/$USER/.qe-f1-build` (falls back to
`~/.cache/qe-f1-install/build`). Download cache: `~/.cache/qe-f1-install/downloads`.

## Options

```
--prefix DIR         install location          (default: $HOME/opt/qe/7.6-<toolchain>)
--toolchain NAME     intel | gnu               (default: intel)
--compiler NAME      intel only: ifort | ifx   (default: ifort)
--openmp on|off      hybrid MPI+OpenMP build   (default: off, pure MPI)
--jobs N             parallel build jobs       (default: 16)
--build-root DIR     scratch for sources/build
--cache-dir DIR      download cache
--no-test            skip the post-install smoke test
--slurm-test ACCT    also run the smoke test as a SLURM job charged to project ACCT
--reconfigure        redo configure/build/install even if already done
--clean              delete the build directory first (downloads are kept)
--force-host         allow a machine that does not look like Forerunner 1
--dry-run            print the plan and exit
--verbose            stream build output to the terminal as well as the logs
```

Environment overrides: `QE_PREFIX`, `QE_BUILD_ROOT`, `QE_CACHE_DIR`, `QE_JOBS`.

### Toolchains

| | `intel` (default) | `gnu` |
|---|---|---|
| module(s) | `intel/2024_01_46` | `gcc/11.2.0` + `openmpi/5.0.2` |
| Fortran | `ifort` 2021.11 (classic; `--compiler ifx` selects ifx 2024.0.2, see note) | gfortran 11.2 |
| MPI | Intel MPI 2021.11 | Open MPI 5.0.2 |
| BLAS/LAPACK/ScaLAPACK | MKL 2024.0 (`mkl_intel_lp64`, `mkl_blacs_intelmpi`) | MKL 2024.0 (`mkl_gf_lp64`, `mkl_blacs_openmpi`) |
| FFT | MKL DFTI (native) | MKL FFTW3 interface |

Both are pure-MPI by default (`OMP_NUM_THREADS=1`); `--openmp on` switches to threaded MKL
and hybrid execution.

Why ifort and not ifx: the ifx shipped in `intel/2024_01_46` (2024.0.2) crashes with an internal
compiler error on `PHonon/PH/symdynph_gq.f90` of QE 7.6. ifort from the same module builds
everything. When the site installs a newer oneAPI, pin it in `versions.lock` and try `--compiler ifx`.

## Running jobs

```bash
source ~/opt/qe/7.6-intel/env.sh
cp ~/opt/qe/7.6-intel/share/qe-f1-install/qe.sbatch .
# edit: --account (your project code), --partition, --nodes, input file name
sbatch qe.sbatch pw.in
```

Partition cheat-sheet (see `man.twcc.ai/@f1-manual/partition`): `development` (≤1120 cores, 8 h,
for tests), `ct112` (≤112 cores, 96 h), `ct448`, `ct1k`, … Each node has 2 × 56-core Xeon 8480+
and 512 GB; the template uses 56 MPI ranks per node.

## How reproducibility is achieved

- **Every external input is pinned in one file, `versions.lock`**: QE tarball URL + sha256,
  the git commits of the three submodules a CPU build compiles (wannier90, libmbd, devxlib),
  the exact site module names, and the smoke-test reference energy. The scripts contain no
  version numbers.
- **Checksums are enforced**, not just recorded: a tarball or pseudopotential that does not
  match aborts the run; submodules are fetched by commit hash and verified with `rev-parse`.
  The pinned hashes are also cross-checked against `external/submodule_commit_hash_records`
  inside the tarball, so a silent drift between the two is impossible.
- **The build is described, not discovered.** Compilers, MPI, BLAS/LAPACK vendor, ScaLAPACK
  and FFT backend are passed explicitly to CMake. QE cannot quietly fall back to its internal
  reference LAPACK or FFTW.
- **The result is self-describing**: `BUILDINFO.json` records everything above plus compiler
  versions, the loaded modules, the full cmake command, the host and the installer's own git
  commit. Two installations can be diffed.
- **Verified, not assumed**: `ldd pw.x` must resolve every library through `env.sh` alone, and
  the smoke test must reproduce QE's own reference energy for `pw_scf/scf.in` to 1e-4 Ry.

## Engineering notes

- **Idempotent and resumable.** Each stage (fetch → configure → build → install → test) leaves
  a stamp tied to a fingerprint of `(version, toolchain, compiler, openmp, prefix)`. Re-running
  after an interruption continues; changing an option re-runs only what that option affects.
  `--reconfigure` and `--clean` are the two escape hatches.
- **Fails loudly and early.** `set -Eeuo pipefail`, a preflight that checks host, modules,
  cmake ≥ 3.20, disk space and write permissions before anything is downloaded, and an error
  trap that prints the last 40 lines of the failing stage's log with its path.
- **Works without an interactive shell.** `module` is a shell function that scripts do not
  inherit; the installer drives Lmod through `$LMOD_CMD` directly, so it also works from cron,
  `nohup`, or a job script.
- **No writes outside the three directories it tells you about** (prefix, build root, cache).
  Uninstall is `rm -rf <prefix>`.
- **Login-node friendly**: 16 build jobs by default; the smoke test pins MPI to shared memory
  (`I_MPI_FABRICS=shm`) so it never probes the InfiniBand fabric from the login node.
- Linted with ShellCheck in CI (`.github/workflows/lint.yml`).

## Layout

```
install.sh              entry point; stages and option parsing
versions.lock           all pins (edit this to bump QE or a module)
lib/common.sh           logging, error trap, checksums, Lmod driver, stage stamps
lib/toolchain_intel.sh  module loads + cmake flags for the Intel toolchain
lib/toolchain_gnu.sh    same for GNU + Open MPI + MKL
templates/              env.sh, Lmod modulefile, SLURM job script (rendered at install time)
tests/smoke.sh          the verification program (installed as bin/qe-smoke-test)
tests/smoke/            2-atom Si input + Si.pz-vbc.UPF (from the QE pseudopotential library)
```

## Validation record

What has actually been run on `ilgn01` (Forerunner 1 login node), 2026-09-27:

| Check | Result |
|---|---|
| Fresh install, `intel` toolchain, defaults | 6 min 20 s end to end (download 3 s, submodules 12 s, configure 9 s, build 366 s with 16 jobs, install 3 s) |
| Executables | 106 `*.x` in `bin/` (pw, ph, cp, neb, pp, projwfc, epw, wannier90, …) |
| `ldd pw.x` after `source env.sh` | 0 unresolved libraries |
| Smoke test, login node, 4 and 8 MPI ranks | total energy −15.79449454 Ry vs reference −15.79449593 Ry (Δ = 1.4 × 10⁻⁶ Ry) |
| Smoke test as a SLURM job (`--slurm-test`, partition `development`, 8 ranks on a compute node) | PASS, same energy |
| `module use …/modulefiles && module load qe/7.6-intel` | loads `intel/2024_01_46` via `depends_on`, `pw.x` on PATH |
| Second run of `install.sh` | all build stages skipped, post-install files refreshed, smoke test re-run: 1 s |
| `--compiler ifx` | fails: ifx 2024.0.2 internal compiler error in `PHonon/PH/symdynph_gq.f90` (documented above) |
| `--toolchain gnu` (gcc 11.2 + Open MPI 5.0.2 + MKL) | 3 min 39 s with cached download/submodules; 106 executables; smoke test PASS with the same total energy on 4 ranks |
| ShellCheck | clean (`shellcheck -x -s bash install.sh lib/*.sh tests/smoke.sh`) |

Disk footprint: 1.2 GB installed, 1.9 GB build tree (deletable), 84 MB download cache.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `host 'xxx' does not look like Forerunner 1` | You are not on `ilgn*`. This installer is site-specific; `--force-host` only makes sense if the same modules exist. |
| `module intel/2024_01_46 not found` | The site renamed/retired the module. Update `versions.lock`. |
| `checksum mismatch` | Corrupt download or upstream re-tagged the release. Delete the file named in the message and re-run; if it persists, do **not** override the checksum — investigate. |
| `git fetch` of a submodule fails | Login node needs HTTPS access to github.com and gitlab.com. |
| smoke test fails with MPI errors | Run it inside a job (`--slurm-test <account>`) — some login nodes restrict process launching. |
| `error #5633: Internal compiler error` | That is ifx 2024.0.2 on PHonon; the default `--compiler ifort` avoids it. |

## License

The installer is MIT licensed. Quantum ESPRESSO is GPL-2.0 and is downloaded from its
upstream repository at install time; nothing from QE is redistributed here except the
pseudopotential file `tests/smoke/Si.pz-vbc.UPF` from the QE pseudopotential library (GPL).

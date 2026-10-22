# Reproducible R runtime

Run `bash scripts/install.sh` from the repository, then use `scripts/Rscript` for all
project commands. The default runtime is `/workspace/.bart-runtime`, outside Git.
`BART_RUNTIME` may select another dedicated absolute directory.

`renv.lock` was generated with `renv::snapshot()` from the tested R 4.5.0 library.
`runtime-sources.json` additionally pins the exact Debian binary archives and the
immutable CRAN GitHub mirror source for dbarts 0.9-34. Debian archive SHA-256 values
were checked against apt's signature-verified trixie package metadata. The installer
retains HTTPS verification and verifies every downloaded artifact against these
committed hashes. It does not alter system packages or disable verification.

The cloud installer targets Debian 13 x86_64 with its existing compiler and shared
system libraries. It extracts packages into the dedicated directory and relocates
R's local launcher/configuration links. Other operating systems can use a native R
installation and `renv::restore()` with this lockfile, but that route has not been
validated in this environment. The lockfile records package versions; the runtime
manifest records the actual tested distribution artifacts.

Installation is repeatable: matching installed artifacts are retained, and each run
checks all locked package versions and runs a small dbarts fit. No project-wide
automatic `.Rprofile` activation is used; the wrapper explicitly selects the pinned
library and avoids unrelated user/site startup files.

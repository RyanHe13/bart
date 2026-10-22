#!/usr/bin/env bash
# Install the pinned Debian 13 / amd64 runtime without changing the host OS.
# All downloads retain TLS verification and must match the committed SHA-256.
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export BART_RUNTIME="${BART_RUNTIME:-/workspace/.bart-runtime}"
for program in python3 curl dpkg-deb gcc g++ make; do
  command -v "$program" >/dev/null || { printf 'Missing prerequisite: %s\n' "$program" >&2; exit 1; }
done
python3 - "$project_dir" "$BART_RUNTIME" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import subprocess
import sys

project, root = map(Path, sys.argv[1:])
if not root.is_absolute() or root in (Path('/'), Path('/workspace'), Path('/tmp'), project):
    raise SystemExit('BART_RUNTIME must name a dedicated absolute runtime directory.')
if platform.machine() != 'x86_64':
    raise SystemExit('This runtime manifest requires x86_64; use renv.lock with native R on other platforms.')
manifest = json.loads((project / 'renv/runtime-sources.json').read_text())
downloads = root / 'downloads'
downloads.mkdir(parents=True, exist_ok=True)
(root / 'library').mkdir(exist_ok=True)

def sha(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()

def fetch(url, digest, name):
    dest = downloads / name
    if dest.exists():
        if sha(dest) == digest:
            return dest
        raise SystemExit(f'Cached checksum mismatch: {dest}. Inspect/remove this file before retrying.')
    # Reuse the apt-verified bootstrap archives if present.
    apt_copy = root / 'apt/archives' / name
    if apt_copy.is_file() and sha(apt_copy) == digest:
        return apt_copy
    partial = dest.with_name(dest.name + '.partial')
    subprocess.run(['curl', '--fail', '--location', '--silent', '--show-error',
                    '--connect-timeout', '30', '--max-time', '300',
                    url, '--output', str(partial)], check=True)
    if sha(partial) != digest:
        partial.unlink()
        raise SystemExit(f'Download checksum mismatch for {name}; artifact rejected.')
    partial.replace(dest)
    return dest

records = manifest['debian_packages']
packages_digest = hashlib.sha256(json.dumps(records, sort_keys=True).encode()).hexdigest()
stamp = root / 'debian-extracted.sha256'
ready = stamp.exists() and stamp.read_text().strip() == packages_digest
ready = ready and (root / 'usr/bin/Rscript').exists() and (root / 'usr/lib/R/site-library/posterior').exists()
if not ready:
    for package in records:
        archive = fetch(package['url'], package['sha256'], package['file'])
        subprocess.run(['dpkg-deb', '-x', str(archive), str(root)], check=True)
    # Relocate Debian's configuration symlinks only inside the dedicated runtime.
    etc = root / 'usr/lib/R/etc'
    for entry in etc.iterdir():
        if entry.is_symlink():
            target = root / str(entry.readlink()).lstrip('/')
            entry.unlink()
            if target.exists():
                entry.symlink_to(target)
            elif entry.name == 'Renviron':
                entry.write_text((etc / 'Renviron.ucf').read_text())
            else:
                raise SystemExit(f'Missing packaged R configuration: {target}')
    for entry in [root / 'usr/lib/R/bin/R', root / 'usr/bin/R']:
        contents = entry.read_text()
        for name, old in [('R_HOME_DIR', '/usr/lib/R'), ('R_SHARE_DIR', '/usr/share/R/share'),
                          ('R_INCLUDE_DIR', '/usr/share/R/include'), ('R_DOC_DIR', '/usr/share/R/doc')]:
            contents = contents.replace(f'{name}={old}', f'{name}=' + shlex.quote(str(root) + old))
        entry.write_text(contents)
    stamp.write_text(packages_digest + '\n')

env = dict(os.environ, RHOME=str(root / 'usr/lib/R'), R_HOME=str(root / 'usr/lib/R'),
           R_LIBS_USER=str(root / 'library'), R_LIBS_SITE=str(root / 'usr/lib/R/site-library'),
           R_ENVIRON_USER='/dev/null', R_PROFILE_USER='/dev/null',
           R_ENVIRON_SITE='/dev/null', R_PROFILE_SITE='/dev/null')
dbarts = manifest['dbarts']
dbarts_stamp = root / 'dbarts-source.sha256'
installed = dbarts_stamp.exists() and dbarts_stamp.read_text().strip() == dbarts['sha256']
installed = installed and (root / 'library/dbarts/DESCRIPTION').exists()
if not installed:
    archive = fetch(dbarts['url'], dbarts['sha256'], 'dbarts-0.9-34.tar.gz')
    env['MAKEFLAGS'] = '-j' + str(min(4, os.cpu_count() or 1))
    subprocess.run([str(root / 'usr/lib/R/bin/R'), 'CMD', 'INSTALL', '--no-multiarch',
                    '--no-build-vignettes', '--library=' + str(root / 'library'), str(archive)],
                   env=env, check=True)
    dbarts_stamp.write_text(dbarts['sha256'] + '\n')

# A complete lock-version check detects missing or mismatched dependencies.
verify = '''args <- commandArgs(TRUE)
lock <- jsonlite::fromJSON(args[1], simplifyVector=FALSE)
stopifnot(as.character(getRversion()) == lock$R$Version)
for (p in names(lock$Packages)) {
  actual <- packageDescription(p)$Version
  if (is.null(actual) || actual != lock$Packages[[p]]$Version)
    stop("Locked package mismatch: ", p)
}
set.seed(20261023)
x <- matrix(rnorm(100), ncol=2)
fit <- dbarts::bart(x, x[,1]+rnorm(50), ntree=10, nskip=10, ndpost=5,
                    nchain=1, nthread=1, verbose=FALSE)
stopifnot(all(is.finite(fit$yhat.train)), length(fit$sigma)==5)
cat("Pinned R runtime and dbarts smoke test passed.\\n")
'''
subprocess.run([str(root / 'usr/bin/Rscript'), '-e', verify, str(project / 'renv.lock')], env=env, check=True)
PY
if [[ -f "$project_dir/scripts/build_native.R" ]]; then
  "$project_dir/scripts/Rscript" "$project_dir/scripts/build_native.R"
fi

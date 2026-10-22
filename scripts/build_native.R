#!/usr/bin/env Rscript
# Run from any directory. Only ignored build products are written. The cache
# key covers source contents, R ABI identity, and compiler identity.
args <- commandArgs(trailingOnly = FALSE)
script_arg <- grep("^--file=", args, value = TRUE)
if (length(script_arg) != 1L) stop("Invoke with Rscript scripts/build_native.R")
script <- normalizePath(sub("^--file=", "", script_arg), mustWork = TRUE)
root <- dirname(dirname(script))
source <- file.path(root, "src", "ssm_native.c")
output <- file.path(root, "artifacts", "native")
build <- file.path(output, "build")
dir.create(build, recursive = TRUE, showWarnings = FALSE)
library_path <- file.path(output, paste0("bartssm", .Platform$dynlib.ext))
stamp <- file.path(output, "build-key.txt")
hasher <- Sys.which("sha256sum")
if (!nzchar(hasher)) stop("sha256sum is required for native build cache validation")
hash_line <- system2(hasher, shQuote(c(source, script)), stdout = TRUE)
if (!is.null(attr(hash_line, "status"))) stop("Cannot hash native source")
source_hash <- vapply(strsplit(hash_line, "[[:space:]]+"), `[`, character(1), 1L)
compiler <- system2(file.path(R.home("bin"), "R"), c("CMD", "config", "CC"), stdout = TRUE)
if (!is.null(attr(compiler, "status"))) stop("Cannot identify R C compiler")
compiler_version <- system2(strsplit(compiler[[1L]], "[[:space:]]+")[[1L]][1L], "--version", stdout = TRUE)
key <- c(source_hash, R.version.string, R.version$platform, compiler[[1L]], compiler_version[[1L]])
if (file.exists(library_path) && file.exists(stamp) &&
    identical(readLines(stamp, warn = FALSE), key) &&
    !"--force" %in% commandArgs(trailingOnly = TRUE)) {
  cat("Native SSM backend already matches source/runtime:", library_path, "\n")
  quit(status = 0L)
}
file.copy(source, file.path(build, "ssm_native.c"), overwrite = TRUE)
unlink(file.path(build, c("ssm_native.o", paste0("ssm_native", .Platform$dynlib.ext))))
link_flags <- vapply(c("LAPACK_LIBS", "BLAS_LIBS", "FLIBS"), function(flag) {
  output <- system2(file.path(R.home("bin"), "R"), c("CMD", "config", flag), stdout = TRUE)
  if (!is.null(attr(output, "status"))) stop("Cannot resolve R linker flag ", flag)
  paste(output, collapse = " ")
}, character(1))
link_tokens <- unlist(strsplit(paste(link_flags, collapse = " "), "[[:space:]]+"))
# Minimal runtime images contain the verified versioned runtime libraries but
# may omit development-package symlinks. Resolve those through the compiler;
# this adds neither packages nor files outside the ignored build directory.
versions <- c(lapack = "3", blas = "3", gfortran = "5")
compiler_command <- strsplit(compiler[[1L]], "[[:space:]]+")[[1L]][1L]
for (lib in names(versions)) {
  token <- paste0("-l", lib)
  if (!token %in% link_tokens) next
  plain <- paste0("lib", lib, ".so")
  found <- system2(compiler_command, paste0("-print-file-name=", plain), stdout = TRUE)
  if (!length(found) || !file.exists(found[[1L]])) {
    soname <- paste0(plain, ".", versions[[lib]])
    found <- system2(compiler_command, paste0("-print-file-name=", soname), stdout = TRUE)
    if (!length(found) || !file.exists(found[[1L]])) stop("Required R numerical library unavailable: ", soname)
    link_tokens[link_tokens == token] <- shQuote(normalizePath(found[[1L]], mustWork = TRUE))
  }
}
Sys.setenv(PKG_LIBS = paste(link_tokens, collapse = " "))
old <- setwd(build)
staged_library <- file.path(build, paste0("bartssm", .Platform$dynlib.ext))
status <- system2(file.path(R.home("bin"), "R"),
                  c("CMD", "SHLIB", "-o", shQuote(staged_library), "ssm_native.c"))
setwd(old)
if (status != 0L || !file.exists(staged_library)) stop("Native SSM build failed")
# Atomic replacement keeps existing R processes mapped to the old inode safe.
if (!file.rename(staged_library, library_path)) stop("Cannot publish native build atomically")
dyn.load(library_path)
if (!is.loaded("bart_ssm_scalar_filter", PACKAGE = "bartssm") ||
    !is.loaded("bart_ssm_scalar_ffbs", PACKAGE = "bartssm") ||
    !is.loaded("bart_ssm_diagonal_filter", PACKAGE = "bartssm") ||
    !is.loaded("bart_ssm_small_ffbs", PACKAGE = "bartssm")) stop("Built library lacks registered SSM entry points")
writeLines(key, stamp)
cat("Built native SSM backend:", library_path, "\n")

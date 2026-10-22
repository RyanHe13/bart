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
hash_line <- system2(hasher, shQuote(source), stdout = TRUE)
if (!is.null(attr(hash_line, "status"))) stop("Cannot hash native source")
source_hash <- strsplit(hash_line[[1L]], "[[:space:]]+")[[1L]][1L]
compiler <- system2(file.path(R.home("bin"), "R"), c("CMD", "config", "CC"), stdout = TRUE)
if (!is.null(attr(compiler, "status"))) stop("Cannot identify R C compiler")
compiler_version <- system2(strsplit(compiler[[1L]], "[[:space:]]+")[[1L]][1L], "--version", stdout = TRUE)
key <- c(source_hash, R.version.string, R.version$platform, compiler[[1L]], compiler_version[[1L]])
if (file.exists(library_path) && file.exists(stamp) &&
    identical(readLines(stamp, warn = FALSE), key) &&
    !"--force" %in% commandArgs(trailingOnly = TRUE)) {
  cat("Native scalar SSM backend already matches source/runtime:", library_path, "\n")
  quit(status = 0L)
}
file.copy(source, file.path(build, "ssm_native.c"), overwrite = TRUE)
unlink(file.path(build, c("ssm_native.o", paste0("ssm_native", .Platform$dynlib.ext))))
old <- setwd(build)
status <- system2(file.path(R.home("bin"), "R"),
                  c("CMD", "SHLIB", "-o", shQuote(library_path), "ssm_native.c"))
setwd(old)
if (status != 0L || !file.exists(library_path)) stop("Native scalar SSM build failed")
dyn.load(library_path)
if (!is.loaded("bart_ssm_scalar_filter", PACKAGE = "bartssm") ||
    !is.loaded("bart_ssm_scalar_ffbs", PACKAGE = "bartssm")) stop("Built library lacks registered SSM entry points")
writeLines(key, stamp)
cat("Built native scalar SSM backend:", library_path, "\n")

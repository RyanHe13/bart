#!/usr/bin/env Rscript
# Reproduce the static-BART mixing audit from simulated data, not an old run.
# Usage: scripts/Rscript scripts/audit_mixing.R
# Each invocation executes immutable source copies in a new artifacts directory.
args <- commandArgs(trailingOnly = TRUE)
script_arg <- grep("^--file=", commandArgs(), value = TRUE)
if (length(script_arg) != 1L) stop("Run with scripts/Rscript scripts/audit_mixing.R")
script_path <- normalizePath(sub("^--file=", "", script_arg), mustWork = TRUE)
root <- dirname(dirname(script_path))
if (identical(args, "--help")) {
  cat("Usage: scripts/Rscript scripts/audit_mixing.R\n",
      "Runs the fixed-seed static BART audit in a new artifacts directory.\n",
      "Includes 20/100/200-tree adapter runs and uninterrupted dbarts controls.\n", sep = "")
  quit(status = 0L)
}
if (!requireNamespace("jsonlite", quietly = TRUE)) stop("Run scripts/install.sh first")
json_write <- function(value, path) {
  jsonlite::write_json(value, path, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null")
}
file_hash <- function(path) {
  ans <- system2("sha256sum", shQuote(path), stdout = TRUE)
  if (!is.null(attr(ans, "status"))) stop("SHA-256 failed for ", path)
  strsplit(ans[[1L]], "[[:space:]]+")[[1L]][1L]
}
runtime_info <- function() {
  list(R = R.version.string, platform = R.version$platform,
       packages = setNames(lapply(c("dbarts", "posterior", "jsonlite", "renv"),
                                  function(p) packageDescription(p)$Version),
                           c("dbarts", "posterior", "jsonlite", "renv")))
}

if (!length(args)) {
  artifact_root <- file.path(root, "artifacts")
  dir.create(artifact_root, showWarnings = FALSE)
  stamp <- format(Sys.time(), "%Y%m%dT%H%M%OS6Z", tz = "UTC")
  stamp <- gsub("[.]", "", stamp)
  out <- tempfile(paste0(stamp, "-mixing-audit-"), tmpdir = artifact_root)
  if (!dir.create(out)) stop("Cannot create unique audit directory")
  out <- normalizePath(out)
  config <- list(schema_version = 1L, task = "static_bart_mixing_audit",
    phase = "exploratory", seed = 20261124L,
    simulation = list(n = 480L, train = 360L, scenario = "no_drift"),
    adapter = list(trees = c(20L, 100L, 200L), chains = 4L, burn = 1000L, draws = 1000L),
    uninterrupted_short = list(trees = 20L, chains = 4L, burn = 1000L, draws = 1000L),
    uninterrupted_long = list(trees = 200L, chains = 4L, burn = 5000L, draws = 10000L),
    diagnostic_positions = c(1L, 91L, 180L, 270L, 360L),
    diagnostic_thresholds = list(rhat_strictly_below = 1.01, ess_bulk_min = 400L, ess_tail_min = 400L))
  json_write(config, file.path(out, "config.json"))
  relative <- c(unlist(lapply(c("R", "scripts", "src"), function(d) {
    list.files(file.path(root, d), recursive = FALSE, full.names = FALSE) |>
      file.path(d, x = _)
  })), "renv.lock", "renv/runtime-sources.json")
  relative <- relative[file.exists(file.path(root, relative)) &
                         !dir.exists(file.path(root, relative))]
  hashes <- list()
  for (path in relative) {
    destination <- file.path(out, "source", path)
    dir.create(dirname(destination), recursive = TRUE, showWarnings = FALSE)
    if (!file.copy(file.path(root, path), destination, copy.mode = TRUE)) stop("Cannot snapshot ", path)
    hashes[[path]] <- file_hash(destination)
  }
  old <- setwd(root)
  git <- function(arguments) {
    ans <- suppressWarnings(system2("git", arguments, stdout = TRUE, stderr = FALSE))
    if (!is.null(attr(ans, "status"))) return(NULL)
    paste(ans, collapse = "\n")
  }
  system2("git", c("diff", "HEAD", "--", "."), stdout = file.path(out, "tracked_changes.diff"))
  metadata <- list(run_id = basename(out), started_at = stamp, status = "running",
    seed = config$seed, chain_seeds = config$seed + 10007L * (0:3),
    config_sha256 = file_hash(file.path(out, "config.json")),
    git_commit = git(c("rev-parse", "HEAD")), git_branch = git(c("branch", "--show-current")),
    git_status = git(c("status", "--porcelain")),
    tracked_diff_sha256 = file_hash(file.path(out, "tracked_changes.diff")),
    source_sha256 = hashes, runtime = runtime_info(),
    interpretation = "Static BART sampler diagnostic audit; no hypothesis or predictive-performance claim.",
    native_backend = "disabled; this audit does not sample latent states")
  setwd(old)
  json_write(metadata, file.path(out, "metadata.json"))
  cat("Audit directory:", out, "\n")
  start <- proc.time()[["elapsed"]]
  status <- tryCatch(system2(file.path(out, "source/scripts/Rscript"),
    c(shQuote(file.path(out, "source/scripts/audit_mixing.R")), "--worker", shQuote(out)),
    stdout = file.path(out, "run.log"), stderr = file.path(out, "run.log")),
    error = function(e) { metadata$error <<- conditionMessage(e); 1L })
  metadata$elapsed_seconds <- proc.time()[["elapsed"]] - start
  metadata$exit_code <- status
  metadata$status <- if (status == 0L) "completed" else "failed"
  summary_path <- file.path(out, "execution_summary.json")
  if (file.exists(summary_path)) metadata$result <- jsonlite::read_json(summary_path)
  json_write(metadata, file.path(out, "metadata.json"))
  cat(paste(readLines(file.path(out, "run.log"), warn = FALSE), collapse = "\n"), "\n")
  cat("Audit status:", metadata$status, "elapsed:", metadata$elapsed_seconds, "seconds\n")
  quit(status = if (status == 0L) 0L else 1L)
}

if (length(args) != 2L || args[1L] != "--worker") stop("Use --help for invocation")
out <- normalizePath(args[2L], mustWork = TRUE)
config <- jsonlite::read_json(file.path(out, "config.json"), simplifyVector = TRUE)
Sys.setenv(BART_SOURCE_ROOT = root)
options(bart.native = FALSE, warn = 1)
for (name in c("ssm", "bart_adapter", "metrics", "air")) source(file.path(root, "R", paste0(name, ".R")))
writeLines(capture.output(sessionInfo()), file.path(out, "session_info.txt"))
z <- simulate_air(n = config$simulation$n, scenario = config$simulation$scenario, seed = config$seed)
saveRDS(z, file.path(out, "simulation_truth.rds"))
json_write(list(generator = "simulate_air", seed = config$seed, n = length(z$y),
                truth_sha256 = file_hash(file.path(out, "simulation_truth.rds"))),
           file.path(out, "simulation_manifest.json"))
train <- seq_len(config$simulation$train)
test <- seq.int(config$simulation$train + 1L, config$simulation$n)
prep <- air_preprocess(z$y[train], z$x[train, ], z$x[test, ])
positions <- config$diagnostic_positions
rows <- list()
run_case <- function(id, method, trees, burn, draws, computation) {
  cat("Starting", id, "\n")
  start <- proc.time()[["elapsed"]]
  row <- data.frame(case = id, method = method, trees = trees, chains = 4L,
    burn = burn, draws = draws, elapsed_seconds = NA_real_, execution_status = "running",
    max_rhat = NA_real_, min_ess_bulk = NA_real_, min_ess_tail = NA_real_,
    passed = FALSE, error = "", stringsAsFactors = FALSE)
  tryCatch({
    object <- force(computation)
    diagnostic_draws <- if (method == "adapter") object$diagnostics else object
    tab <- diagnose_chains(diagnostic_draws)
    row$elapsed_seconds <- proc.time()[["elapsed"]] - start
    row$execution_status <- "completed"
    row$max_rhat <- max(tab$rhat)
    row$min_ess_bulk <- min(tab$ess_bulk)
    row$min_ess_tail <- min(tab$ess_tail)
    row$passed <- all(tab$passed %in% TRUE)
    write.csv(tab, file.path(out, paste0(id, "_diagnostics.csv")), row.names = FALSE)
    saveRDS(object, file.path(out, paste0(id, "_draws.rds")))
  }, error = function(e) {
    row$elapsed_seconds <<- proc.time()[["elapsed"]] - start
    row$execution_status <<- "failed"
    row$error <<- conditionMessage(e)
  })
  rows[[length(rows) + 1L]] <<- row
  write.csv(do.call(rbind, rows), file.path(out, "summary.csv"), row.names = FALSE)
  print(row)
}
for (trees in config$adapter$trees) {
  run_case(paste0("adapter_", trees), "adapter", trees,
    config$adapter$burn, config$adapter$draws,
    fit_air(z$y[train], z$x[train, ], "bart_static",
      list(chains = config$adapter$chains, burn = config$adapter$burn,
           draws = config$adapter$draws, trees = trees, seed = config$seed), z$x[test, ]))
}
uninterrupted <- function(control) {
  raw_draws <- array(NA_real_, c(control$draws, control$chains, length(positions) + 1L),
    dimnames = list(NULL, NULL, c("r", paste0("f_", positions))))
  for (chain in seq_len(control$chains)) {
    seed <- config$seed + 10007L * (chain - 1L)
    set.seed(seed)
    adapter <- bart_create(prep$x, prep$y, x_test = prep$x,
      trees = control$trees, seed = seed, sigma = prep$sigest)
    raw <- adapter$sampler$run(numBurnIn = control$burn, numSamples = control$draws,
                              updateState = FALSE)
    raw_draws[, chain, ] <- cbind(as.numeric(raw$sigma)^2, t(raw$train[positions, ]))
    cat("Completed uninterrupted", control$trees, "trees, chain", chain, "\n")
  }
  raw_draws
}
for (name in c("uninterrupted_short", "uninterrupted_long")) {
  control <- config[[name]]
  id <- paste0("uninterrupted_", control$trees, if (name == "uninterrupted_long") "_long" else "")
  run_case(id, "uninterrupted_dbarts", control$trees, control$burn, control$draws,
           uninterrupted(control))
}
summary <- do.call(rbind, rows)
json_write(list(executed_cases = nrow(summary),
                failed_cases = sum(summary$execution_status != "completed"),
                diagnostic_pass = all(summary$passed),
                diagnostic_failures = summary$case[!summary$passed]),
           file.path(out, "execution_summary.json"))
quit(status = if (any(summary$execution_status != "completed")) 1L else 0L)

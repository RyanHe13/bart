#!/usr/bin/env Rscript
# Training and exploratory evaluation only. Confirmation is deliberately gated.
args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 2L) stop("Usage: scripts/Rscript scripts/experiment.R CONFIG OUTPUT")
config <- jsonlite::fromJSON(args[1], simplifyVector = TRUE)
out <- normalizePath(args[2], mustWork = TRUE)
if (!identical(config$phase, "exploratory")) stop("Confirmation data is sealed in this runner")
# Rscript parses its file incrementally. Execute immutable per-run copies so
# concurrent research edits cannot alter the running driver or sourced models.
script_arg <- grep("^--file=", commandArgs(), value = TRUE)[1L]
source_root <- dirname(dirname(normalizePath(sub("^--file=", "", script_arg))))
Sys.setenv(BART_SOURCE_ROOT = source_root)
options(bart.native.path = file.path(source_root, "native", paste0("bartssm", .Platform$dynlib.ext)))
for (f in c("ssm", "bart_adapter", "metrics", "evaluation", "yield", "air")) source(file.path(source_root, "R", paste0(f, ".R")))
options(warn = 1)
writeLines(capture.output(sessionInfo()), file.path(out, "session_info.txt"))
scores <- list(); diagnostics <- list(); prediction_rows <- list(); failures <- list()
control <- config$control
control$seed <- config$seed
dir.create(file.path(out, "fits"), showWarnings = FALSE)

flush_results <- function() {
  for (name in c("scores", "diagnostics", "prediction_rows", "failures")) {
    values <- get(name, envir = .GlobalEnv)
    if (length(values)) write.csv(do.call(rbind, values), file.path(out, paste0(name, ".csv")), row.names = FALSE)
  }
}

check_fit <- function(fit, case, model) {
  if (is.null(fit$diagnostics)) return(NA)
  tab <- diagnose_chains(fit$diagnostics)
  tab$case <- case; tab$model <- model
  diagnostics[[length(diagnostics) + 1L]] <<- tab
  pass <- all(tab$passed %in% TRUE)
  if (!is.null(fit$stage1_diagnostics)) {
    first <- diagnose_chains(fit$stage1_diagnostics)
    first$case <- case; first$model <- paste0(model, ":first_stage")
    diagnostics[[length(diagnostics) + 1L]] <<- first
    pass <- pass && all(first$passed %in% TRUE)
  }
  pass
}

check_prediction <- function(fit, case, model, draws, labels, prior_pass,
                              conditional_mean_draws = NULL, conditional_labels = NULL) {
  # Plug-in random-walk/VAR simulations are not posterior MCMC chains.
  if (is.null(fit$diagnostics)) return(prior_pass)
  observed <- diagnose_prediction_draws(draws, fit$control$draws, fit$control$chains,
    labels = labels, prefix = "predictive_observation", max_points = if (nrow(draws) <= 6L) 6L else 5L)
  if (is.null(conditional_mean_draws)) {
    conditional <- data.frame(variable = "predictive_mean_unavailable", rhat = NA_real_,
      ess_bulk = NA_real_, ess_tail = NA_real_, passed = FALSE,
      reason = "Conditional predictive mean samples unavailable")
  } else {
    if (is.null(conditional_labels)) conditional_labels <- labels
    conditional <- diagnose_prediction_draws(conditional_mean_draws,
      fit$control$draws, fit$control$chains, labels = conditional_labels,
      prefix = "predictive_mean", max_points = if (nrow(conditional_mean_draws) <= 6L) 6L else 5L)
  }
  tab <- rbind(observed, conditional)
  tab$case <- case; tab$model <- model
  diagnostics[[length(diagnostics) + 1L]] <<- tab
  isTRUE(prior_pass) && all(tab$passed %in% TRUE)
}

record <- function(case, model, truth, draws, labels, elapsed, diagnostic_pass,
                    state_rmse = NA_real_, function_rmse = NA_real_, fit = NULL,
                    conditional_mean_draws = NULL, conditional_labels = NULL) {
  draws <- as.matrix(draws)
  if (nrow(draws) != length(truth)) stop("Prediction shape mismatch")
  metrics <- score_predictions(truth, draws)
  if (metrics$n < 1L) stop("No finite target observations were scored")
  if (!is.null(fit)) diagnostic_pass <- check_prediction(fit, case, model, draws,
    labels, diagnostic_pass, conditional_mean_draws, conditional_labels)
  scores[[length(scores) + 1L]] <<- data.frame(case = case, model = model, as.data.frame(metrics),
      elapsed_seconds = elapsed, diagnostic_pass = diagnostic_pass,
      state_rmse = state_rmse, function_rmse = function_rmse, stringsAsFactors = FALSE)
  each <- score_predictions_each(truth, draws)
  each$case <- case; each$model <- model; each$label <- labels
  prediction_rows[[length(prediction_rows) + 1L]] <<- each
  flush_results()
}

attempt <- function(case, model, code) {
  cat(format(Sys.time()), case, model, "\n")
  tryCatch(force(code), error = function(e) {
    failures[[length(failures) + 1L]] <<- data.frame(case = case, model = model, error = conditionMessage(e))
    cat("FAILED:", conditionMessage(e), "\n")
    flush_results()
    NULL
  })
}

if (config$task == "yield") {
  data <- read.csv(config$data$path, check.names = FALSE)
  data$date <- as.Date(data$date)
  data <- data[data$date >= as.Date(config$data$start), ]
  features <- config$data$features
  if (!all(features %in% names(data))) stop("Requested macro series absent; no silent proxy substitution")
  if ("macro_cumfns" %in% features && config$data$capacity_series != "CUMFNS") stop("Capacity proxy must be explicitly named")
  yields <- c("SVENY01", "SVENY02", "SVENY03", "SVENY05", "SVENY07", "SVENY10")
  for (month in config$evaluation$target_months) {
    idx <- which(format(data$date, "%Y-%m") == month)
    if (length(idx) != 1L || idx < 121L) stop("Target month missing or insufficient training data")
    if (data$date[idx] >= as.Date(config$evaluation$confirmation_start)) stop("Attempted to open sealed confirmation target")
    past <- data[seq_len(idx - 1L), ]
    if (any(!is.finite(as.matrix(past[, features])))) stop("Training macros missing; cannot silently drop months")
    for (model in config$models) attempt(month, model, {
      start <- proc.time()[3]
      fit <- fit_yield(as.matrix(past[, yields]), as.matrix(past[, features]), model,
                       control = control, x_next = as.numeric(data[idx, features]))
      elapsed <- proc.time()[3] - start
      saveRDS(fit, file.path(out, "fits", paste0(month, "-", model, ".rds")))
      pass <- check_fit(fit, month, model)
      record(month, model, as.numeric(data[idx, yields]), t(fit$predictions), yields, elapsed, pass,
             fit = fit, conditional_mean_draws = if (!is.null(fit$prediction_means)) t(fit$prediction_means) else NULL)
    })
  }
} else if (config$task == "air") {
  data <- read.csv(config$data$path, check.names = FALSE)
  if (!identical(config$evaluation$split, "validation")) stop("Air confirmation data remains sealed")
  train <- data[data$split == "train", ]
  evaluation <- data[data$split == "validation", ]
  features <- config$data$features
  if (any(grepl("GT|CO", features))) stop("Reference-instrument columns cannot be input features")
  for (model in config$models) attempt("air_validation", model, {
    start <- proc.time()[3]
    fit <- fit_air(train$CO, as.matrix(train[, features]), model, control,
                   x_test = as.matrix(evaluation[, features]))
    elapsed <- proc.time()[3] - start
    saveRDS(fit, file.path(out, "fits", paste0(model, ".rds")))
    pass <- check_fit(fit, "air_validation", model)
    for (gap in config$evaluation$gaps_hours) {
      mask <- make_gap_mask(evaluation$CO, evaluation[, features], gap,
                            config$evaluation$max_blocks, config$evaluation$min_observed_fraction)
      ids <- which(mask$score)
      diagnostic_positions <- ids[unique(round(seq(1, length(ids), length.out = min(5L, length(ids)))))]
      pred <- predict_air_online(fit, evaluation$CO, reference_allowed = mask$reference_allowed,
        seed = config$seed + gap, diagnostic_positions = diagnostic_positions)
      draws <- pred$draws
      record(paste0("gap", gap), model, evaluation$CO[ids], draws[ids, , drop = FALSE],
             paste0(evaluation$timestamp[ids], ";block=", mask$blocks[ids]), elapsed, pass,
             fit = fit, conditional_mean_draws = pred$conditional_mean_draws,
             conditional_labels = evaluation$timestamp[pred$diagnostic_positions])
      write.csv(data.frame(timestamp = evaluation$timestamp, block = mask$blocks,
                           reference_allowed = mask$reference_allowed, scored = mask$score),
                file.path(out, paste0("mask_gap", gap, ".csv")), row.names = FALSE)
    }
  })
} else if (config$task == "simulation_yield") {
  s <- config$simulation
  missing_modes <- if (is.null(s$missing_modes)) "none" else s$missing_modes
  for (scenario in s$scenarios) for (noise in s$noise) for (missing in missing_modes) for (rep in seq_len(s$replicates)) {
    # Common random numbers isolate the effect of measurement-noise magnitude.
    seed <- config$seed + rep + 100L * match(scenario, s$scenarios)
    generated <- simulate_yield(n = s$n, scenario = scenario, noise = noise, seed = seed, missing = missing)
    case <- if (is.null(s$missing_modes)) paste(scenario, noise, rep, sep = "_") else paste(scenario, noise, missing, rep, sep = "_")
    saveRDS(generated, file.path(out, "fits", paste0(case, "-truth.rds")))
    for (model in config$models) attempt(case, model, {
      start <- proc.time()[3]
      run_control <- control; run_control$seed <- seed
      fit <- fit_yield(generated$y, generated$x, model, run_control, x_next = generated$x_next)
      elapsed <- proc.time()[3] - start
      saveRDS(fit, file.path(out, "fits", paste0(case, "-", model, ".rds")))
      pass <- check_fit(fit, case, model)
      state_error <- sqrt(mean((fit$state_mean - generated$states)^2))
      function_error <- sqrt(mean((fit$function_mean - generated$f[-1, , drop = FALSE])^2))
      record(case, model, generated$truth_next, t(fit$predictions), paste0("maturity", 1:6), elapsed, pass,
             state_error, function_error, fit = fit,
             conditional_mean_draws = if (!is.null(fit$prediction_means)) t(fit$prediction_means) else NULL)
    })
  }
} else if (config$task == "simulation_air") {
  s <- config$simulation
  for (scenario in s$scenarios) for (rep in seq_len(s$replicates)) {
    seed <- config$seed + rep + 100L * match(scenario, s$scenarios)
    generated <- simulate_air(n = s$n, scenario = scenario, seed = seed)
    train <- seq_len(s$train_n); test <- seq.int(s$train_n + 1L, s$n)
    case <- paste(scenario, rep, sep = "_")
    saveRDS(generated, file.path(out, "fits", paste0(case, "-truth.rds")))
    for (model in config$models) attempt(case, model, {
      start <- proc.time()[3]
      run_control <- control; run_control$seed <- seed
      fit <- fit_air(generated$y[train], generated$x[train, , drop = FALSE], model, run_control,
                     x_test = generated$x[test, , drop = FALSE])
      allowed <- seq_along(test) %% config$evaluation$reference_every == 0L
      ids <- which(!allowed)
      diagnostic_positions <- ids[unique(round(seq(1, length(ids), length.out = min(5L, length(ids)))))]
      pred <- predict_air_online(fit, generated$y[test], reference_allowed = allowed, seed = seed,
                                 diagnostic_positions = diagnostic_positions)
      elapsed <- proc.time()[3] - start
      saveRDS(fit, file.path(out, "fits", paste0(case, "-", model, ".rds")))
      pass <- check_fit(fit, case, model)
      state_error <- sqrt(mean((fit$state_mean - generated$state[train])^2))
      function_error <- sqrt(mean((fit$function_mean - generated$function_mean[train])^2))
      record(case, model, generated$y[test][ids], pred$draws[ids, , drop = FALSE], as.character(test[ids]),
             elapsed, pass, state_error, function_error, fit = fit,
             conditional_mean_draws = pred$conditional_mean_draws,
             conditional_labels = as.character(test[pred$diagnostic_positions]))
    })
  }
} else stop("Unknown task")

flush_results()
jsonlite::write_json(list(task = config$task, phase = config$phase, completed = length(scores),
  failures = length(failures), confirmation_opened = FALSE,
  inference_warning = "Pilot chains are not automatically converged; inspect diagnostics.csv before substantive claims"),
  file.path(out, "summary.json"), auto_unbox = TRUE, pretty = TRUE)
if (length(failures)) quit(status = 1L)
if (!length(scores)) stop("Zero evaluated results")
cat("Completed", length(scores), "score rows; confirmation data not used.\n")

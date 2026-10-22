# Draw matrices use observations in rows and posterior predictive samples in
# columns. Predictive samples, not latent-function-only samples, are required.

crps_sample <- function(y, draws) {
  draws <- as.numeric(draws)
  if (!length(draws) || !is.finite(y) || any(!is.finite(draws))) return(NA_real_)
  n <- length(draws); ordered <- sort(draws)
  mean(abs(draws - y)) - sum((2 * seq_len(n) - n - 1) * ordered) / n^2
}

score_predictions_each <- function(y, draws) {
  y <- as.numeric(y); draws <- as.matrix(draws)
  if (nrow(draws) != length(y) || ncol(draws) < 1L) stop("draws must be n_observations by n_draws")
  if (any(is.infinite(y))) stop("Truth contains infinite values; use NA for missing targets")
  if (any(!is.finite(draws))) stop("Prediction draws contain nonfinite values")
  qu <- t(apply(draws, 1L, stats::quantile, probs = c(.025, .10, .90, .975), names = FALSE))
  mu <- rowMeans(draws)
  result <- data.frame(y = y, prediction = mu, error = mu - y,
                       squared_error = (mu - y)^2, absolute_error = abs(mu - y),
                       crps = vapply(seq_along(y), function(i) crps_sample(y[i], draws[i, ]), numeric(1)),
                       lower80 = qu[, 2L], upper80 = qu[, 3L],
                       lower95 = qu[, 1L], upper95 = qu[, 4L])
  result$covered80 <- y >= result$lower80 & y <= result$upper80
  result$covered95 <- y >= result$lower95 & y <= result$upper95
  result$width80 <- result$upper80 - result$lower80
  result$width95 <- result$upper95 - result$lower95
  result$row_index <- seq_along(y)
  result$truth <- y
  result$mean <- mu
  result
}

score_predictions <- function(y, draws) {
  scores <- score_predictions_each(y, draws)
  scores <- scores[is.finite(scores$y), , drop = FALSE]
  if (!nrow(scores)) return(list(n = 0L, rmse = NA_real_, mae = NA_real_, crps = NA_real_,
                                coverage80 = NA_real_, width80 = NA_real_, coverage95 = NA_real_, width95 = NA_real_))
  list(n = nrow(scores), rmse = sqrt(mean(scores$squared_error)),
       mae = mean(scores$absolute_error), crps = mean(scores$crps),
       coverage80 = mean(scores$covered80), width80 = mean(scores$width80),
       coverage95 = mean(scores$covered95), width95 = mean(scores$width95))
}

diagnose_chains <- function(draws, rhat_limit = 1.01, ess_min = 400) {
  if (length(dim(draws)) != 3L) stop("Diagnostics require iteration by chain by variable array")
  variable <- dimnames(draws)[[3L]]
  if (is.null(variable)) variable <- paste0("variable_", seq_len(dim(draws)[3L]))
  dimnames(draws)[[3L]] <- variable
  unavailable <- !requireNamespace("posterior", quietly = TRUE)
  if (unavailable || dim(draws)[1L] < 4L || dim(draws)[2L] < 2L) {
    reason <- if (unavailable) "posterior package unavailable" else "Need >=4 draws and >=2 independent chains"
    return(data.frame(variable = variable, rhat = NA_real_, ess_bulk = NA_real_,
                      ess_tail = NA_real_, passed = FALSE, reason = reason))
  }
  ans <- as.data.frame(posterior::summarise_draws(posterior::as_draws_array(draws),
                                                "rhat", "ess_bulk", "ess_tail"))
  ans$passed <- with(ans, is.finite(rhat) & is.finite(ess_bulk) & is.finite(ess_tail) &
                       rhat < rhat_limit & ess_bulk >= ess_min & ess_tail >= ess_min)
  ans$reason <- ifelse(ans$passed, "", "Convergence/ESS threshold not met")
  ans
}

# Predictions use observation rows and chain-major sample columns: all draws
# from chain 1, then chain 2, etc. Diagnose selected functionals, not an
# aggregate mean that has already averaged away chain information.
diagnose_prediction_draws <- function(draws, draws_per_chain, chains,
                                      labels = NULL, positions = NULL,
                                      prefix = "prediction", max_points = 5L,
                                      rhat_limit = 1.01, ess_min = 400) {
  draws <- as.matrix(draws)
  if (!is.numeric(draws) || length(draws_per_chain) != 1L ||
      length(chains) != 1L || draws_per_chain < 1L || chains < 1L ||
      draws_per_chain != as.integer(draws_per_chain) || chains != as.integer(chains) ||
      ncol(draws) != draws_per_chain * chains)
    stop("Prediction columns must equal draws_per_chain * chains in chain-major order")
  if (is.null(labels)) labels <- as.character(seq_len(nrow(draws)))
  if (length(labels) != nrow(draws)) stop("Prediction labels do not match rows")
  if (length(max_points) != 1L || !is.finite(max_points) || max_points < 1L)
    stop("max_points must be positive")
  if (is.null(positions)) positions <- seq_len(nrow(draws))
  if (anyNA(positions) || any(positions != as.integer(positions)) ||
      any(positions < 1L | positions > nrow(draws))) stop("Invalid diagnostic positions")
  positions <- unique(as.integer(positions))
  valid <- rowSums(!is.finite(draws)) == 0L
  positions <- positions[valid[positions]]
  if (!length(positions)) {
    return(data.frame(variable = paste0(prefix, "_unavailable"), rhat = NA_real_,
                      ess_bulk = NA_real_, ess_tail = NA_real_, passed = FALSE,
                      reason = "No finite predictive rows available for diagnostics"))
  }
  if (length(positions) > max_points)
    positions <- positions[unique(round(seq(1, length(positions), length.out = max_points)))]
  variables <- make.unique(paste0(prefix, "_", labels[positions]))
  by_chain <- array(NA_real_, c(draws_per_chain, chains, length(positions)),
                    dimnames = list(NULL, paste0("chain", seq_len(chains)), variables))
  for (j in seq_along(positions))
    by_chain[, , j] <- matrix(draws[positions[j], ], nrow = draws_per_chain, ncol = chains)
  diagnose_chains(by_chain, rhat_limit = rhat_limit, ess_min = ess_min)
}

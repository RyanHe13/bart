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

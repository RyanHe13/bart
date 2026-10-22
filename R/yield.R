# Dynamic Nelson--Siegel experiments. Yields are annualised percentage points;
# maturities are months. Macro row t is available before observing yield row t.

ns_loadings <- function(maturities_months = c(12, 24, 36, 60, 84, 120),
                        lambda = 0.0609) {
  stopifnot(all(is.finite(maturities_months)), all(maturities_months > 0),
            length(lambda) == 1L, is.finite(lambda), lambda > 0)
  u <- lambda * maturities_months
  slope <- -expm1(-u) / u
  out <- cbind(level = 1, slope = slope, curvature = slope - exp(-u))
  rownames(out) <- paste0(maturities_months, "m")
  out
}

yield_ols_states <- function(y, H) {
  y <- as.matrix(y)
  out <- matrix(NA_real_, nrow(y), ncol(H))
  for (t in seq_len(nrow(y))) {
    ok <- is.finite(y[t, ])
    if (sum(ok) < ncol(H) || qr(H[ok, , drop = FALSE])$rank < ncol(H))
      stop("Each training month needs at least three identifiable maturities; ",
           "do not interpolate future yields into missing months.")
    out[t, ] <- qr.solve(H[ok, , drop = FALSE], y[t, ok])
  }
  colnames(out) <- colnames(H)
  out
}

.yield_control <- function(control) {
  defaults <- list(seed = 1L, chains = 4L, burn = 1000L, draws = 1000L,
                   thin = 1L, trees = 50L, a_bound = 0.995,
                   a_prior_mean = c(0.95, 0.85, 0.75), a_prior_sd = 0.25,
                   variance_floor = 1e-6, bart_k = 2,
                   q_prior_df = 3, q_prior_quantile = 0.90,
                   r_prior_shape = 2.5, progress = FALSE)
  out <- utils::modifyList(defaults, control)
  for (key in c("chains", "draws", "thin", "trees"))
    if (length(out[[key]]) != 1L || out[[key]] < 1 ||
        out[[key]] != as.integer(out[[key]])) stop("Invalid control: ", key)
  if (out$burn < 0 || out$burn != as.integer(out$burn)) stop("Invalid burn")
  if (out$a_bound <= 0 || out$a_bound >= 1) stop("a_bound must be in (0,1)")
  out
}

.yield_rmvnorm <- function(mean, covariance) {
  covariance <- (covariance + t(covariance)) / 2
  ee <- eigen(covariance, symmetric = TRUE)
  if (min(ee$values) < -1e-7) stop("Invalid covariance in yield model")
  as.numeric(mean + ee$vectors %*% (sqrt(pmax(ee$values, 0)) * rnorm(length(mean))))
}

.yield_truncnorm <- function(mean, sd, lower, upper) {
  lo <- (lower - mean) / sd
  hi <- (upper - mean) / sd
  # Use the upper tail when both standardized bounds are positive.
  if (lo > 0) {
    p_lo <- pnorm(hi, lower.tail = FALSE)
    p_hi <- pnorm(lo, lower.tail = FALSE)
    if (p_hi <= p_lo) stop("Truncated normal tail underflow; inspect chain")
    mean + sd * qnorm(runif(1, p_lo, p_hi), lower.tail = FALSE)
  } else {
    p_lo <- pnorm(lo)
    p_hi <- pnorm(hi)
    if (p_hi <= p_lo) stop("Truncated normal tail underflow; inspect chain")
    mean + sd * qnorm(runif(1, p_lo, p_hi))
  }
}

.yield_prepare <- function(y, x, x_next, maturities_months, control) {
  y <- as.matrix(y)
  storage.mode(y) <- "double"
  if (nrow(y) < 12L || ncol(y) != length(maturities_months))
    stop("Expected at least 12 training months and one column per maturity")
  if (any(is.infinite(y))) stop("Yield matrix contains infinite values")
  x <- as.matrix(x)
  if (nrow(x) != nrow(y) || !ncol(x) || any(!is.finite(x)))
    stop("x must be finite, with one row per training month")
  x_next <- matrix(as.numeric(x_next), nrow = 1L)
  if (ncol(x_next) != ncol(x) || any(!is.finite(x_next)))
    stop("x_next must contain one finite, available-at-origin macro vector")
  H <- ns_loadings(maturities_months)
  beta <- yield_ols_states(y, H)
  n <- nrow(y)
  prev <- beta[-n, , drop = FALSE]
  current <- beta[-1L, , drop = FALSE]
  initial_a <- vapply(seq_len(3L), function(j) {
    cc <- qr.solve(cbind(1, prev[, j]), current[, j])[2L]
    max(-control$a_bound + 0.01, min(control$a_bound - 0.01, cc))
  }, numeric(1))
  anchor <- current - sweep(prev, 2L, initial_a, `*`)
  q0 <- pmax(apply(anchor, 2L, var), control$variance_floor)
  measurement <- y - beta %*% t(H)
  r0 <- pmax(colMeans(measurement^2, na.rm = TRUE), control$variance_floor)
  # Frozen once per fit; identical calibration for two-stage and joint BART.
  x_center <- colMeans(x[-1L, , drop = FALSE])
  x_scale <- apply(x[-1L, , drop = FALSE], 2L, sd)
  x_scale[!is.finite(x_scale) | x_scale < 1e-10] <- 1
  X <- sweep(sweep(x, 2L, x_center, `-`), 2L, x_scale, `/`)
  X_next <- sweep(sweep(x_next, 2L, x_center, `-`), 2L, x_scale, `/`)
  list(y = y, x = X, x_next = X_next, H = H, beta = beta,
       initial_a = initial_a, anchor = anchor, q0 = q0, r0 = r0,
       x_center = x_center, x_scale = x_scale)
}

# Fit one training window and generate one-step posterior predictive draws.
# x[t,] drives beta_t. No test labels or future macro path enter this function.
fit_yield <- function(y, x, model = "bart_joint", control = list(), x_next,
                      maturities_months = c(12, 24, 36, 60, 84, 120)) {
  models <- c("random_walk", "dns_var", "dns_linear", "dns_macro",
              "bart_two_stage", "bart_joint")
  if (!model %in% models) stop("Unknown yield model: ", model)
  ctl <- .yield_control(control)
  d <- .yield_prepare(y, x, x_next, maturities_months, ctl)
  n <- nrow(d$y)
  m <- ncol(d$y)
  k <- 3L
  start <- proc.time()[[3L]]
  nd <- ctl$draws * ctl$chains
  calibration <- list(q0 = d$q0, r0 = d$r0, a_initial = d$initial_a,
                      macro_center = d$x_center, macro_scale = d$x_scale,
                      lambda_per_month = 0.0609,
                      prior_calibration = "Frozen training-window empirical calibration")

  if (model %in% c("random_walk", "dns_var")) {
    set.seed(ctl$seed)
    predicted <- matrix(NA_real_, nd, m)
    if (model == "random_walk") {
      mean_next <- vapply(seq_len(m), function(j)
        tail(d$y[is.finite(d$y[, j]), j], 1L), numeric(1))
      diff_y <- d$y[-1L, , drop = FALSE] - d$y[-n, , drop = FALSE]
      covariance <- diag(pmax(colMeans(diff_y^2, na.rm = TRUE),
                              ctl$variance_floor), m)
      for (i in seq_len(nd)) predicted[i, ] <- .yield_rmvnorm(mean_next, covariance)
      metadata <- list(inference = "Gaussian random walk with fitted diagonal innovation variance")
    } else {
      design <- cbind(1, d$beta[-n, , drop = FALSE])
      penalty <- diag(c(1e-8, rep(1e-6, k)))
      coefficients <- solve(crossprod(design) + penalty,
                            crossprod(design, d$beta[-1L, , drop = FALSE]))
      residual <- d$beta[-1L, , drop = FALSE] - design %*% coefficients
      q <- crossprod(residual) / max(1, nrow(residual) - ncol(design)) + diag(1e-8, k)
      mean_beta <- as.numeric(c(1, d$beta[n, ]) %*% coefficients)
      mean_next <- as.numeric(d$H %*% mean_beta)
      covariance <- d$H %*% q %*% t(d$H) + diag(d$r0, m)
      for (i in seq_len(nd)) predicted[i, ] <- .yield_rmvnorm(mean_next, covariance)
      metadata <- list(inference = "Two-stage OLS full VAR(1), plug-in parameters; no parameter posterior",
                       transition = t(coefficients[-1L, , drop = FALSE]),
                       transition_spectral_radius = max(Mod(eigen(t(coefficients[-1L, ]))$values)))
    }
    colnames(predicted) <- rownames(d$H)
    return(list(model = model, predictions = predicted, diagnostics = NULL,
                state_mean = d$beta, function_mean = NULL,
                calibration = calibration, metadata = metadata,
                elapsed_seconds = proc.time()[[3L]] - start, control = ctl))
  }

  needed <- c("kalman_filter", "ffbs_sample")
  if (any(!vapply(needed, exists, logical(1), mode = "function")))
    stop("Source R/ssm.R before fitting latent yield models")
  is_bart <- model %in% c("bart_two_stage", "bart_joint")
  joint <- model != "bart_two_stage"
  if (is_bart && (!exists("bart_create", mode = "function") ||
                  !exists("bart_step", mode = "function")))
    stop("Source R/bart_adapter.R before fitting BART models")

  diagnostic_names <- c(paste0("a_", colnames(d$H)),
                        paste0("q_", colnames(d$H)),
                        paste0("r_", rownames(d$H)),
                        paste0("f_last_", colnames(d$H)),
                        if (joint) paste0("state_last_", colnames(d$H)))
  diagnostics <- array(NA_real_, c(ctl$draws, ctl$chains, length(diagnostic_names)),
                       dimnames = list(NULL, paste0("chain", seq_len(ctl$chains)), diagnostic_names))
  predicted <- matrix(NA_real_, nd, m, dimnames = list(NULL, rownames(d$H)))
  states_sum <- matrix(0, n, k)
  functions_sum <- matrix(0, n - 1L, k)
  q_shape <- ctl$q_prior_df / 2
  q_rate <- d$q0 * qchisq(1 - ctl$q_prior_quantile, ctl$q_prior_df) / 2
  r_shape <- ctl$r_prior_shape
  r_rate <- (r_shape - 1) * d$r0
  prior_a <- rep_len(ctl$a_prior_mean, k)

  for (chain in seq_len(ctl$chains)) {
    chain_seed <- ctl$seed + 10007L * (chain - 1L)
    set.seed(chain_seed)
    beta <- d$beta
    a <- d$initial_a
    q <- d$q0
    r <- d$r0
    f <- matrix(rep(colMeans(d$anchor), each = n - 1L), n - 1L, k)
    f_next <- colMeans(d$anchor)
    if (is_bart) {
      adapters <- lapply(seq_len(k), function(j)
        bart_create(d$x[-1L, , drop = FALSE], d$anchor[, j],
                    x_test = d$x_next, trees = ctl$trees,
                    seed = chain_seed + 101L * j, sigma = sqrt(d$q0[j]),
                    k = ctl$bart_k, resid_df = ctl$q_prior_df,
                    resid_quant = ctl$q_prior_quantile))
      # Package construction may touch R's RNG; restore a chain-specific stream.
      set.seed(chain_seed + 777L)
    } else {
      Z <- if (model == "dns_macro") cbind(1, d$x[-1L, , drop = FALSE]) else matrix(1, n - 1L, 1L)
      Z_next <- if (model == "dns_macro") c(1, d$x_next) else 1
      coefficient_mean <- matrix(0, ncol(Z), k)
      coefficient_mean[1L, ] <- colMeans(d$anchor)
      coefficient_var <- lapply(seq_len(k), function(j)
        diag(rep(max(d$q0[j], 0.01), ncol(Z)), ncol(Z)))
    }

    retained <- 0L
    total <- ctl$burn + ctl$draws * ctl$thin
    for (iteration in seq_len(total)) {
      if (joint) {
        # beta_1 has a fixed N(0,100I) prior independent of A and Q.
        transitions <- c(list(diag(k)), rep(list(diag(a, k)), n - 1L))
        state_variances <- c(list(matrix(0, k, k)), rep(list(diag(q, k)), n - 1L))
        filter <- kalman_filter(d$y, d$H, transitions, state_variances, diag(r, m),
                                state_offset = rbind(rep(0, k), f),
                                m0 = rep(0, k), P0 = diag(100, k))
        beta <- ffbs_sample(filter)
      }
      previous <- beta[-n, , drop = FALSE]
      current <- beta[-1L, , drop = FALSE]
      # The dynamics coefficient has one stationary truncated-normal update.
      for (j in seq_len(k)) {
        precision <- sum(previous[, j]^2) / q[j] + 1 / ctl$a_prior_sd^2
        variance_a <- 1 / precision
        mean_a <- variance_a * (sum(previous[, j] * (current[, j] - f[, j])) / q[j] +
                                prior_a[j] / ctl$a_prior_sd^2)
        a[j] <- .yield_truncnorm(mean_a, sqrt(variance_a), -ctl$a_bound, ctl$a_bound)
      }
      response <- current - sweep(previous, 2L, a, `*`)
      for (j in seq_len(k)) {
        if (is_bart) {
          step <- bart_step(adapters[[j]], response[, j])
          f[, j] <- as.numeric(step$f_train)
          f_next[j] <- as.numeric(step$f_test)[1L]
          # dbarts alone samples the state innovation variance in BART models.
          q[j] <- step$sigma^2
        } else {
          prior_precision <- solve(coefficient_var[[j]])
          posterior_variance <- solve(crossprod(Z) / q[j] + prior_precision)
          posterior_mean <- posterior_variance %*%
            (crossprod(Z, response[, j]) / q[j] + prior_precision %*% coefficient_mean[, j])
          coefficients <- .yield_rmvnorm(as.numeric(posterior_mean), posterior_variance)
          f[, j] <- as.numeric(Z %*% coefficients)
          f_next[j] <- sum(Z_next * coefficients)
          q[j] <- 1 / rgamma(1L, q_shape + (n - 1L) / 2,
                            rate = q_rate[j] + sum((response[, j] - f[, j])^2) / 2)
        }
      }
      measurement_residual <- d$y - beta %*% t(d$H)
      for (j in seq_len(m)) {
        ok <- is.finite(measurement_residual[, j])
        r[j] <- 1 / rgamma(1L, r_shape + sum(ok) / 2,
                          rate = r_rate[j] + sum(measurement_residual[ok, j]^2) / 2)
      }
      if (any(!is.finite(c(a, q, r, f_next))) || any(c(q, r) <= 0))
        stop("Non-finite yield sampler state at chain ", chain, " iteration ", iteration)
      if (iteration > ctl$burn && (iteration - ctl$burn) %% ctl$thin == 0L) {
        retained <- retained + 1L
        beta_next <- a * beta[n, ] + f_next + rnorm(k, sd = sqrt(q))
        out_row <- (chain - 1L) * ctl$draws + retained
        predicted[out_row, ] <- as.numeric(d$H %*% beta_next) + rnorm(m, sd = sqrt(r))
        diagnostics[retained, chain, ] <- c(a, q, r, f[n - 1L, ],
                                           if (joint) beta[n, ])
        states_sum <- states_sum + beta
        functions_sum <- functions_sum + f
      }
      if (isTRUE(ctl$progress) && iteration %% 100L == 0L)
        message(model, " chain ", chain, "/", ctl$chains, " iteration ", iteration, "/", total)
    }
  }
  list(model = model, predictions = predicted, diagnostics = diagnostics,
       state_mean = states_sum / nd, function_mean = functions_sum / nd,
       calibration = calibration,
       metadata = list(inference = if (joint) "Joint latent-state Gibbs" else
                         "Fixed cross-sectional NS estimates; conditional dynamics posterior",
                       state_prior = "beta_1 ~ N(0,100 I); Q1=0, A1=I",
                       dynamics = "Diagonal A, diagonal Q, diagonal R; |a_j| < a_bound",
                       q_prior = "Scaled inverse chi-squared calibrated once from OLS residuals",
                       r_prior = "Inverse gamma, shape 2.5, mean equal to frozen OLS residual variance",
                       variance_owner = if (is_bart) "dbarts: Q; outer Gibbs: R" else "outer Gibbs: Q and R",
                       fixed_quantities = if (!joint) "Cross-sectional OLS state path; excluded from stochastic diagnostics" else character(0),
                       prediction_target = "Future observed yields including measurement noise"),
       elapsed_seconds = proc.time()[[3L]] - start, control = ctl)
}

simulate_yield <- function(n = 240L,
                           scenario = c("nonlinear", "linear", "conditional_persistence"),
                           noise = c("low", "high"), seed = 1L,
                           maturities_months = c(12, 24, 36, 60, 84, 120),
                           missing = c("none", "sparse")) {
  scenario <- match.arg(scenario)
  noise <- match.arg(noise)
  missing <- match.arg(missing)
  if (n < 12L) stop("n must be at least 12")
  set.seed(seed)
  H <- ns_loadings(maturities_months)
  total <- n + 1L
  x <- matrix(0, total, 3L, dimnames = list(NULL, c("policy", "activity", "inflation")))
  macro_ar <- c(0.7, 0.85, 0.6)
  x[1L, ] <- rnorm(3L)
  for (t in 2:total) x[t, ] <- macro_ar * x[t - 1L, ] + rnorm(3L, sd = sqrt(1 - macro_ar^2))
  a <- c(0.97, 0.90, 0.80)
  center <- c(4, -1, 0.5)
  linear_f <- x %*% matrix(c(0.025, -0.01, 0.02,
                             -0.035, 0.04, 0.015,
                             0.02, -0.025, 0.04), 3L, 3L)
  f <- sweep(linear_f, 2L, (1 - a) * center, `+`)
  if (scenario != "linear") {
    f[, 1L] <- f[, 1L] + 0.04 * (x[, 1L] > 0 & x[, 3L] > 0)
    f[, 2L] <- f[, 2L] + 0.10 * sin(x[, 1L]) + 0.10 * (x[, 2L] > 0 & x[, 3L] > 0)
    f[, 3L] <- f[, 3L] + 0.08 * (x[, 2L]^2 - 1)
  }
  a_path <- matrix(rep(a, each = total), total, 3L)
  if (scenario == "conditional_persistence") a_path[, 2L] <- 0.70 + 0.27 * plogis(1.5 * x[, 1L])
  q <- c(0.035, 0.07, 0.08)^2
  r <- rep(if (noise == "low") 0.015^2 else 0.15^2, nrow(H))
  beta <- matrix(0, total, 3L, dimnames = list(NULL, colnames(H)))
  beta[1L, ] <- center + rnorm(3L, sd = 0.1)
  for (t in 2:total) beta[t, ] <- a_path[t, ] * beta[t - 1L, ] + f[t, ] + rnorm(3L, sd = sqrt(q))
  y <- beta %*% t(H) + matrix(rnorm(total * nrow(H)), total, nrow(H)) *
    matrix(rep(sqrt(r), each = total), total, nrow(H))
  observed <- y[seq_len(n), , drop = FALSE]
  if (missing == "sparse") {
    # Retain at least four maturities so all methods share an identifiable
    # cross-sectional initialisation; never compress the monthly time grid.
    for (t in seq_len(n)) {
      absent <- which(runif(nrow(H)) < 0.25)
      if (length(absent) > 2L) absent <- sample(absent, 2L)
      observed[t, absent] <- NA_real_
    }
  }
  list(y = observed, x = x[seq_len(n), , drop = FALSE],
       x_next = x[total, ], states = beta[seq_len(n), , drop = FALSE],
       f = f[seq_len(n), , drop = FALSE],
       truth_next = y[total, ], y_next = y[total, ],
       state_next = beta[total, ], f_next = f[total, ],
       a_path = a_path[seq_len(n), , drop = FALSE],
       q = q, r = r, scenario = scenario, noise = noise, missing = missing, seed = seed,
       maturities_months = maturities_months)
}

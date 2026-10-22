# Air-quality online calibration. BART models the observation mean; a zero-mean
# AR(1) models residual calibration bias. All state steps preserve the hour grid.

air_controls <- function(control = list()) {
  defaults <- list(seed = 20261023L, chains = 4L, burn = 1000L, draws = 1000L,
                   trees = 50L, thin = 1L, rho = 0.99, k = 2,
                   resid_df = 3, resid_quant = 0.90, q_prior_df = 6,
                   q_increment_fraction = 0.03, progress = FALSE)
  out <- utils::modifyList(defaults, control)
  for (nm in c("chains", "draws", "trees", "thin")) {
    if (length(out[[nm]]) != 1L || !is.finite(out[[nm]]) || out[[nm]] < 1 ||
        out[[nm]] != as.integer(out[[nm]])) stop("Invalid air control: ", nm)
    out[[nm]] <- as.integer(out[[nm]])
  }
  if (!is.finite(out$burn) || out$burn < 0 || out$burn != as.integer(out$burn))
    stop("burn must be a nonnegative integer")
  if (!is.finite(out$rho) || abs(out$rho) >= 1)
    stop("rho must be strictly between -1 and 1")
  if (!is.finite(out$q_prior_df) || out$q_prior_df <= 2 ||
      !is.finite(out$q_increment_fraction) || out$q_increment_fraction <= 0)
    stop("State variance prior requires df > 2 and a positive increment scale")
  out
}

air_valid_rows <- function(x) rowSums(!is.finite(x)) == 0L

air_preprocess <- function(y, x, x_test = NULL) {
  x <- as.matrix(x)
  storage.mode(x) <- "double"
  y <- as.numeric(y)
  if (nrow(x) != length(y) || ncol(x) < 1L) stop("Incompatible air y/x")
  forbidden <- grepl("\\(GT\\)", colnames(x), fixed = FALSE)
  if (length(forbidden) && any(forbidden))
    stop("Reference-analyzer (GT) columns cannot be predictors")
  if (is.null(x_test)) x_test <- matrix(numeric(0), 0L, ncol(x))
  x_test <- as.matrix(x_test)
  storage.mode(x_test) <- "double"
  if (ncol(x_test) != ncol(x)) stop("x_test must match training columns")
  if (!is.null(colnames(x)) && !is.null(colnames(x_test)) &&
      !identical(colnames(x), colnames(x_test))) stop("Predictor order changed")
  train_valid <- air_valid_rows(x)
  test_valid <- air_valid_rows(x_test)
  observed <- train_valid & is.finite(y)
  if (sum(observed) < max(12L, ncol(x) + 2L))
    stop("Too few observed reference values with complete inputs")
  center <- colMeans(x[train_valid, , drop = FALSE])
  scale <- apply(x[train_valid, , drop = FALSE], 2L, stats::sd)
  scale[!is.finite(scale) | scale < 1e-10] <- 1
  normalize <- function(xx) sweep(sweep(xx, 2L, center, "-"), 2L, scale, "/")
  z <- normalize(x)
  z_test <- normalize(x_test)
  yy <- y[observed]
  variance <- max(stats::var(yy), 1e-8)
  design <- cbind(intercept = 1, z[observed, , drop = FALSE])
  ridge <- diag(c(1e-8, rep(1e-4, ncol(x))))
  initial_coef <- as.numeric(solve(crossprod(design) + ridge,
                                  crossprod(design, yy)))
  initial_function <- rep(NA_real_, length(y))
  initial_function[train_valid] <- as.numeric(cbind(1, z[train_valid, , drop = FALSE]) %*% initial_coef)
  # Fixed empirical calibration, computed once. This quantity never changes in
  # the outer Gibbs sampler, preserving the residual and tree priors.
  sigest <- sqrt(max(mean((yy - initial_function[observed])^2), variance * 0.01))
  list(y = y, x = z, x_test = z_test, observed = observed,
       train_valid = train_valid, test_valid = test_valid,
       center = center, scale = scale, variance = variance, sigest = sigest,
       initial_function = initial_function, initial_coef = initial_coef)
}

air_residual_prior <- function(sigest, control) {
  # Scaled inverse-chi-square prior, identical to dbarts chisq(df, quantile)
  # calibrated with sigest: P(sigma < sigest) = resid_quant.
  c(shape = control$resid_df / 2,
    rate = sigest^2 * stats::qchisq(1 - control$resid_quant,
                                  df = control$resid_df) / 2)
}

air_state_prior <- function(variance, control) {
  shape <- control$q_prior_df / 2
  mean_q <- variance * control$q_increment_fraction^2
  c(shape = shape, rate = (shape - 1) * mean_q, initial = mean_q)
}

air_filter <- function(y, f, rho, q, r) {
  residual <- y - f
  residual[!is.finite(residual)] <- NA_real_
  kalman_filter(matrix(residual, ncol = 1L), matrix(1), matrix(rho),
                matrix(q), matrix(r), m0 = 0,
                P0 = matrix(q / (1 - rho^2)))
}

air_ig <- function(shape, rate) 1 / stats::rgamma(1L, shape = shape, rate = rate)

air_sampler_diagnostics <- function(q, r, b, f, positions, dynamic,
                                    function_uncertain = TRUE) {
  values <- c(r = r)
  if (function_uncertain) {
    values <- c(values, f[positions])
    names(values) <- c("r", paste0("f_", positions))
  }
  if (dynamic) values <- c(q = q, b_terminal = tail(b, 1L), values)
  values
}

# fit_air's x_test contains covariates only; held-out reference labels are never
# passed to the fitting function. Missing training targets remain missing.
fit_air <- function(y, x, model = "bart_joint", control = list(), x_test = NULL) {
  allowed <- c("bart_static", "linear_dynamic", "bart_two_stage", "bart_joint")
  if (!model %in% allowed) stop("Unknown air model: ", model)
  control <- air_controls(control)
  prep <- air_preprocess(y, x, x_test)
  n <- length(prep$y)
  n_test <- nrow(prep$x_test)
  observed_idx <- which(prep$observed)
  train_idx <- which(prep$train_valid)
  test_idx <- which(prep$test_valid)
  prediction_x <- rbind(prep$x[train_idx, , drop = FALSE],
                        prep$x_test[test_idx, , drop = FALSE])
  positions <- unique(observed_idx[pmax(1L, round(seq(1, length(observed_idx), length.out = 5L)))])
  count <- control$draws * control$chains
  dynamic <- model != "bart_static"
  param_prior <- air_residual_prior(prep$sigest, control)
  q_prior <- air_state_prior(prep$variance, control)
  predictions <- matrix(NA_real_, n_test, count)
  params <- matrix(NA_real_, count, 3L, dimnames = list(NULL, c("rho", "q", "r")))
  terminal <- matrix(0, count, 2L, dimnames = list(NULL, c("mean", "variance")))
  function_sum <- rep(0, n)
  state_sum <- rep(0, n)
  diag_names <- names(air_sampler_diagnostics(1, 1, rep(0, n),
                                             rep(0, n), positions, dynamic,
                                             model != "bart_two_stage"))
  diagnostic_draws <- array(NA_real_, c(control$draws, control$chains, length(diag_names)),
                            dimnames = list(NULL, paste0("chain", seq_len(control$chains)), diag_names))
  stage1 <- NULL
  if (model == "bart_two_stage") {
    stage1 <- fit_air(y, x, model = "bart_static", control = control, x_test = x_test)
    fixed_train <- stage1$function_mean
    fixed_test <- if (n_test) rowMeans(stage1$f_test) else numeric(0)
    fixed_test[!prep$test_valid] <- NA_real_
  }

  for (chain in seq_len(control$chains)) {
    chain_seed <- as.integer(control$seed + 10007L * (chain - 1L))
    set.seed(chain_seed)
    q <- q_prior[["initial"]]
    r <- prep$sigest^2
    b <- rep(0, n)
    f <- prep$initial_function
    f_test <- rep(NA_real_, n_test)
    adapter <- NULL
    if (model %in% c("bart_static", "bart_joint")) {
      adapter <- bart_create(prep$x[observed_idx, , drop = FALSE],
                             prep$y[observed_idx], x_test = prediction_x,
                             trees = control$trees, seed = chain_seed,
                             sigma = prep$sigest, k = control$k,
                             resid_df = control$resid_df,
                             resid_quant = control$resid_quant)
    }
    if (model == "bart_two_stage") {
      f <- fixed_train
      f_test <- fixed_test
    }
    if (model == "linear_dynamic") {
      # Fixed weak Gaussian coefficients, centered predictors. The intercept
      # has an explicit proper prior and no separate free state mean exists.
      X <- cbind(1, prep$x[observed_idx, , drop = FALSE])
      X_pred <- cbind(1, prediction_x)
      coefficient_prior_mean <- c(mean(prep$y[observed_idx]), rep(0, ncol(prep$x)))
      coefficient_prior_variance <- prep$variance * c(100, rep(4, ncol(prep$x)))
      coefficient_precision <- diag(1 / coefficient_prior_variance)
      XtX <- crossprod(X)
    }
    iterations <- control$burn + control$draws * control$thin
    kept <- 0L
    for (iteration in seq_len(iterations)) {
      if (dynamic) {
        filter <- air_filter(prep$y, f, control$rho, q, r)
        b <- as.numeric(ffbs_sample(filter))
      }
      if (model %in% c("bart_static", "bart_joint")) {
        response <- prep$y[observed_idx] - b[observed_idx]
        step <- bart_step(adapter, response)
        r <- step$sigma^2
        f[train_idx] <- step$f_test[seq_along(train_idx)]
        if (length(test_idx)) f_test[test_idx] <- step$f_test[length(train_idx) + seq_along(test_idx)]
      } else if (model == "linear_dynamic") {
        coefficient_cov <- solve(XtX / r + coefficient_precision)
        coefficient_mean <- as.numeric(coefficient_cov %*%
          (crossprod(X, prep$y[observed_idx] - b[observed_idx]) / r +
             coefficient_precision %*% coefficient_prior_mean))
        coefficient <- coefficient_mean + as.numeric(t(chol(coefficient_cov)) %*% stats::rnorm(length(coefficient_mean)))
        prediction <- as.numeric(X_pred %*% coefficient)
        f[train_idx] <- prediction[seq_along(train_idx)]
        if (length(test_idx)) f_test[test_idx] <- prediction[length(train_idx) + seq_along(test_idx)]
      }
      if (dynamic) {
        # b_1 has the stationary marginal N(0,q/(1-rho^2)); x_0 was integrated
        # out by filtering, hence this initial-state contribution is required.
        squared_innovations <- (1 - control$rho^2) * b[1L]^2 +
          sum((b[-1L] - control$rho * b[-n])^2)
        q <- air_ig(q_prior[["shape"]] + n / 2,
                    q_prior[["rate"]] + squared_innovations / 2)
        if (model != "bart_joint") {
          residual <- prep$y[observed_idx] - f[observed_idx] - b[observed_idx]
          r <- air_ig(param_prior[["shape"]] + length(observed_idx) / 2,
                      param_prior[["rate"]] + sum(residual^2) / 2)
        }
      }
      if (iteration > control$burn && (iteration - control$burn) %% control$thin == 0L) {
        kept <- kept + 1L
        column <- (chain - 1L) * control$draws + kept
        if (n_test) predictions[, column] <- f_test
        params[column, ] <- c(control$rho, if (dynamic) q else 0, r)
        if (dynamic) {
          final_filter <- air_filter(prep$y, f, control$rho, q, r)
          terminal[column, ] <- c(final_filter$filtered_mean[n, 1L],
                                  final_filter$filtered_cov[1L, 1L, n])
        }
        function_sum[train_idx] <- function_sum[train_idx] + f[train_idx]
        state_sum <- state_sum + b
        diagnostic_draws[kept, chain, ] <- air_sampler_diagnostics(q, r, b, f, positions,
                                                                  dynamic, model != "bart_two_stage")
      }
      if (isTRUE(control$progress) && iteration %% 100L == 0L)
        message(model, ": chain ", chain, " iteration ", iteration, "/", iterations)
    }
  }
  function_mean <- function_sum / count
  function_mean[!prep$train_valid] <- NA_real_
  result <- list(model = model, control = control, f_test = predictions, params = params,
                 terminal = terminal, diagnostics = diagnostic_draws,
                 state_mean = state_sum / count, function_mean = function_mean,
                 observed = prep$observed, train_valid = prep$train_valid,
                 test_valid = prep$test_valid,
                 preprocessing = list(center = prep$center, scale = prep$scale),
                 priors = list(r = param_prior, q = q_prior, sigest = prep$sigest),
                 inference = "Fixed rho; offline posterior fitting; test parameters frozen; equal-weight filtering ensemble.")
  if (!is.null(stage1)) {
    result$stage1_diagnostics <- stage1$diagnostics
    result$inference <- paste(result$inference,
      "Two-stage freezes the static BART posterior mean; function uncertainty is not propagated in stage two.")
  }
  class(result) <- "air_fit"
  result
}

# Each row's predictive distribution is formed BEFORE consulting that row's
# permitted reference reading. This is an equal-weight frozen-parameter
# filtering ensemble, not a claim of exact sequential parameter Bayes.
predict_air_online <- function(fit, y_test, reference_allowed = rep(FALSE, length(y_test)),
                               seed = 20261024L) {
  y_test <- as.numeric(y_test)
  n <- length(y_test)
  if (nrow(fit$f_test) != n || length(reference_allowed) != n)
    stop("Online prediction inputs do not match fitted x_test")
  if (anyNA(reference_allowed)) stop("reference_allowed must not contain NA")
  allowed <- as.logical(reference_allowed) & is.finite(y_test) & fit$test_valid
  sample_count <- ncol(fit$f_test)
  predictive <- matrix(NA_real_, n, sample_count)
  means <- variances <- rep(NA_real_, n)
  rho <- fit$params[, "rho"]
  q <- fit$params[, "q"]
  r <- fit$params[, "r"]
  m <- fit$terminal[, "mean"]
  P <- fit$terminal[, "variance"]
  set.seed(seed)
  # Vectorize posterior samples, keeping each sample's f/parameters/state
  # paired. RNG consumption is time-major; this source version is recorded in
  # each run manifest, and identical seeds reproduce this implementation.
  for (t in seq_len(n)) {
    m <- rho * m
    P <- rho^2 * P + q
    f <- fit$f_test[t, ]
    valid <- which(is.finite(f))
    if (length(valid)) {
      mu <- f[valid] + m[valid]
      variance <- P[valid] + r[valid]
      predictive[t, valid] <- stats::rnorm(length(valid), mu, sqrt(variance))
      if (length(valid) == sample_count) {
        means[t] <- mean(mu)
        variances[t] <- mean(variance) + mean((mu - means[t])^2)
      }
      if (allowed[t]) {
        K <- P[valid] / (P[valid] + r[valid])
        m[valid] <- m[valid] + K * (y_test[t] - f[valid] - m[valid])
        P[valid] <- (1 - K) * P[valid]
      }
    }
  }
  list(draws = predictive, mean = means, variance = pmax(variances, 0),
       reference_used = allowed, valid = fit$test_valid,
       interpretation = fit$inference)
}

simulate_air <- function(n = 720L, scenario = "drift", seed = 1L) {
  if (!scenario %in% c("no_drift", "drift", "slow_covariates"))
    stop("Unknown air simulation scenario")
  if (n < 30L) stop("n must be at least 30")
  set.seed(seed)
  x <- matrix(stats::rnorm(n * 8L), n, 8L)
  colnames(x) <- c("PT08.S1(CO)", "PT08.S2(NMHC)", "PT08.S3(NOx)",
                   "PT08.S4(NO2)", "PT08.S5(O3)", "T", "RH", "AH")
  if (scenario == "slow_covariates") {
    for (j in seq_len(ncol(x))) {
      for (t in 2:n) x[t, j] <- 0.98 * x[t - 1L, j] + 0.2 * x[t, j]
    }
  }
  f <- 2 + sin(x[, 1L]) + 0.45 * x[, 2L] * x[, 3L] +
    0.35 * (x[, 6L] > 0) + 0.15 * x[, 7L]^2
  rho <- 0.99
  q <- if (scenario == "no_drift") 0 else 0.004
  r <- 0.15^2
  b <- numeric(n)
  if (q > 0) {
    b[1L] <- stats::rnorm(1L, 0, sqrt(q / (1 - rho^2)))
    for (t in 2:n) b[t] <- rho * b[t - 1L] + stats::rnorm(1L, 0, sqrt(q))
  }
  y <- f + b + stats::rnorm(n, 0, sqrt(r))
  list(y = y, x = x, state = b, function_mean = f, rho = rho, q = q, r = r,
       scenario = scenario, seed = seed)
}

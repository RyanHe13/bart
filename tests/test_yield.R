# Run from repository root: scripts/Rscript tests/test_yield.R
source("R/ssm.R")
source("R/bart_adapter.R")
source("R/yield.R")

assert <- function(ok, message) if (!isTRUE(ok)) stop(message, call. = FALSE)
must_error <- function(expr) inherits(try(force(expr), silent = TRUE), "try-error")

H <- ns_loadings()
assert(identical(dim(H), c(6L, 3L)), "NS loading dimensions")
assert(max(abs(H - ns_loadings(c(1, 2, 3, 5, 7, 10), lambda = 12 * 0.0609))) < 1e-14,
       "NS years/months units must agree after lambda conversion")
assert(all(H[, 1L] == 1) && all(diff(H[, 2L]) < 0), "NS level/slope geometry")
assert(must_error(ns_loadings(c(0, 12))), "Invalid maturity was accepted")

set.seed(11)
truth <- matrix(rnorm(90), 30, 3)
y_exact <- truth %*% t(H)
y_exact[seq(1, 30, by = 2), 2L] <- NA_real_
recovered <- yield_ols_states(y_exact, H)
assert(max(abs(recovered - truth)) < 1e-10, "OLS states fail exact recovery with sparse missing maturities")
y_bad <- y_exact
y_bad[1L, 1:4] <- NA_real_
assert(must_error(yield_ols_states(y_bad, H)), "Unidentifiable cross section must fail explicitly")

low <- simulate_yield(n = 50L, scenario = "nonlinear", noise = "low", seed = 191)
high <- simulate_yield(n = 50L, scenario = "nonlinear", noise = "high", seed = 191)
assert(identical(low$states, high$states) && identical(low$x, high$x),
       "Noise comparison must hold latent paths and covariates fixed")
assert(all(high$r > low$r), "High noise scenario did not change measurement noise")
sparse <- simulate_yield(n = 50L, scenario = "nonlinear", noise = "low", seed = 191,
                         missing = "sparse")
assert(identical(sparse$states, low$states) && anyNA(sparse$y) &&
         min(rowSums(is.finite(sparse$y))) >= 4L,
       "Sparse maturities must preserve the underlying paired simulation and time grid")
varying <- simulate_yield(n = 50L, scenario = "conditional_persistence", seed = 12)
assert(sd(varying$a_path[, 2L]) > 0.01 && max(abs(varying$a_path)) < 1,
       "Conditional-persistence DGP must vary slope dynamics and remain stable")

ctl <- list(seed = 391L, chains = 2L, burn = 8L, draws = 12L, trees = 8L)
for (model in c("random_walk", "dns_var", "dns_linear", "dns_macro")) {
  fit <- fit_yield(low$y, low$x, model = model, control = ctl, x_next = low$x_next)
  assert(identical(dim(fit$predictions), c(24L, 6L)) && all(is.finite(fit$predictions)),
         paste(model, "predictive draws are missing or non-finite"))
  assert(identical(dim(fit$prediction_means), dim(fit$predictions)) &&
           identical(colnames(fit$prediction_means), colnames(fit$predictions)) &&
           all(is.finite(fit$prediction_means)),
         paste(model, "conditional prediction means have incorrect draw/maturity layout"))
  if (model %in% c("random_walk", "dns_var")) {
    assert(all(apply(fit$prediction_means, 2L, sd) == 0) && is.null(fit$diagnostics),
           paste(model, "plug-in mean must be fixed and must not receive MCMC diagnostics"))
  }
  assert(all(is.finite(fit$state_mean)), paste(model, "state estimates invalid"))
  if (!is.null(fit$diagnostics)) {
    assert(identical(dim(fit$diagnostics)[1:2], c(12L, 2L)), paste(model, "chain labels lost"))
    a_draws <- fit$diagnostics[, , grep("^a_", dimnames(fit$diagnostics)[[3L]]), drop = FALSE]
    assert(max(abs(a_draws)) < 0.995, "Stationary prior violated")
  }
}

# The forecasting macro vector can affect the forecast but cannot affect the
# fitted training posterior. This detects accidentally appending test rows.
one <- fit_yield(low$y, low$x, "dns_macro", ctl, x_next = low$x_next)
two <- fit_yield(low$y, low$x, "dns_macro", ctl, x_next = low$x_next + 10)
assert(identical(one$state_mean, two$state_mean) && identical(one$diagnostics, two$diagnostics),
       "Forecast macro vector leaked into training inference")
assert(!identical(one$predictions, two$predictions), "Forecast macro information was ignored")

two_stage <- fit_yield(high$y, high$x, "bart_two_stage", ctl, x_next = high$x_next)
joint <- fit_yield(high$y, high$x, "bart_joint", ctl, x_next = high$x_next)
sparse_joint <- fit_yield(sparse$y, sparse$x, "bart_joint", ctl, x_next = sparse$x_next)
assert(identical(two_stage$calibration, joint$calibration),
       "Joint and two-stage comparisons use different frozen prior calibration")
assert(max(abs(two_stage$state_mean - yield_ols_states(high$y, H))) < 1e-10,
       "Two-stage baseline unexpectedly updated fixed NS state estimates")
assert(!any(grepl("^state_last_", dimnames(two_stage$diagnostics)[[3L]])),
       "Fixed OLS states must not be included in stochastic convergence diagnostics")
assert(max(abs(joint$state_mean - two_stage$state_mean)) > 1e-6,
       "Joint model did not update latent states")
assert(all(is.finite(joint$predictions)) && all(is.finite(two_stage$predictions)),
       "BART predictive draws invalid")
assert(identical(dim(joint$prediction_means), dim(joint$predictions)) &&
         identical(dim(two_stage$prediction_means), dim(two_stage$predictions)) &&
         all(is.finite(joint$prediction_means)) && all(is.finite(two_stage$prediction_means)),
       "BART conditional prediction means invalid")
assert(all(is.finite(sparse_joint$predictions)) && nrow(sparse_joint$state_mean) == 50L,
       "Missing-maturity joint run failed or compressed time")
assert(all(apply(joint$predictions, 2L, sd) > 0), "Predictive uncertainty is absent")

bad_x <- low$x
bad_x[4L, 1L] <- NA_real_
assert(must_error(fit_yield(low$y, bad_x, "dns_macro", ctl, x_next = low$x_next)),
       "Missing macro inputs should not be silently imputed")
assert(must_error(fit_yield(low$y, low$x, "not_a_model", ctl, x_next = low$x_next)),
       "Unknown model accepted")
cat("Yield model tests passed: loading units, missing maturities, paired simulation, six models, no forecast leakage, matched priors.\n")

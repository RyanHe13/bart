# Run from repository root after sourcing R/*.R, or source required modules here.
if (!exists("fit_air")) source("R/air.R")
if (!exists("kalman_filter")) source("R/ssm.R")
if (!exists("bart_create")) source("R/bart_adapter.R")

air_expect_error <- function(expr) {
  failed <- inherits(try(force(expr), silent = TRUE), "try-error")
  if (!failed) stop("Expected an air validation error")
}

# A hand-computed filter proves that current/future reference labels never
# affect a prediction made before that reference becomes available.
fake_air <- list(
  f_test = matrix(2, 6, 3),
  params = matrix(rep(c(.9, .04, .25), 3), nrow = 3, byrow = TRUE,
                  dimnames = list(NULL, c("rho", "q", "r"))),
  terminal = matrix(rep(c(.5, .2), 3), nrow = 3, byrow = TRUE,
                    dimnames = list(NULL, c("mean", "variance"))),
  test_valid = rep(TRUE, 6), inference = "test"
)
reference <- c(2, 3, 1, 4, 5, 2)
schedule <- c(FALSE, TRUE, FALSE, FALSE, TRUE, FALSE)
online <- predict_air_online(fake_air, reference, schedule, seed = 82)
m1 <- .9 * .5
p1 <- .9^2 * .2 + .04
m2 <- .9 * m1
p2 <- .9^2 * p1 + .04
k2 <- p2 / (p2 + .25)
m2_updated <- m2 + k2 * (reference[2] - 2 - m2)
stopifnot(abs(online$mean[1] - (2 + m1)) < 1e-12,
          abs(online$mean[2] - (2 + m2)) < 1e-12,
          abs(online$mean[3] - (2 + .9 * m2_updated)) < 1e-12,
          abs(online$variance[2] - (p2 + .25)) < 1e-12)
stopifnot(max(abs(rowMeans(online$conditional_mean_draws) -
                   online$mean[online$diagnostic_positions])) < 1e-12)
hidden_changed <- reference
hidden_changed[!schedule] <- hidden_changed[!schedule] + 1000
hidden_prediction <- predict_air_online(fake_air, hidden_changed, schedule, seed = 82)
stopifnot(identical(online$draws, hidden_prediction$draws))
stopifnot(identical(online$conditional_mean_draws,
                    hidden_prediction$conditional_mean_draws))
future_changed <- reference
future_changed[5] <- -100
future_prediction <- predict_air_online(fake_air, future_changed, schedule, seed = 82)
stopifnot(identical(online$draws[1:5, ], future_prediction$draws[1:5, ]),
          !identical(online$draws[6, ], future_prediction$draws[6, ]))
fake_missing <- fake_air
fake_missing$f_test[2, ] <- NA_real_
fake_missing$test_valid[2] <- FALSE
missing_prediction <- predict_air_online(fake_missing, reference, schedule, seed = 82)
stopifnot(!missing_prediction$reference_used[2],
          all(is.na(missing_prediction$draws[2, ])))

# Reference instruments must not be silently introduced as deployment inputs.
sim_air <- simulate_air(240L, "drift", seed = 41)
bad_x <- sim_air$x
colnames(bad_x)[1] <- "NO2(GT)"
air_expect_error(air_preprocess(sim_air$y, bad_x))
air_expect_error(air_controls(list(rho = 1)))
damaged_y <- sim_air$y[1:190]
damaged_y[20:25] <- NA_real_
damaged_x <- sim_air$x[1:190, ]
damaged_x[60:63, 1] <- NA_real_
prepared <- air_preprocess(damaged_y, damaged_x, sim_air$x[191:240, ])
stopifnot(length(prepared$y) == 190L,
          sum(prepared$observed) == 180L,
          all(is.na(prepared$y[20:25])),
          !any(prepared$observed[60:63]))

# A modest actual posterior fit verifies all four algorithms against a known
# nonlinear calibration problem. This is an implementation test, not a claim
# of convergence or an empirical superiority result.
ctl_air_test <- list(chains = 1L, burn = 80L, draws = 80L, trees = 20L,
                      seed = 314L)
test_air_models <- c("bart_static", "linear_dynamic", "bart_two_stage", "bart_joint")
for (model_air_test in test_air_models) {
  fitted_air <- fit_air(damaged_y, damaged_x, model = model_air_test,
                        control = ctl_air_test, x_test = sim_air$x[191:240, ])
  predicted_air <- predict_air_online(fitted_air, sim_air$y[191:240],
                                      reference_allowed = rep(FALSE, 50), seed = 91)
  stopifnot(identical(dim(predicted_air$draws), c(50L, 80L)),
            all(is.finite(predicted_air$draws)),
            all(fitted_air$params[, "r"] > 0),
            identical(fitted_air$observed, prepared$observed),
            length(fitted_air$state_mean) == 190L)
  # Broad recovery check: a broken constant-mean calibration will fail.
  recovery_mse <- mean((predicted_air$mean - sim_air$function_mean[191:240] -
                         sim_air$state[191:240])^2)
  constant_mse <- mean((mean(damaged_y, na.rm = TRUE) -
                         sim_air$function_mean[191:240] - sim_air$state[191:240])^2)
  stopifnot(recovery_mse < constant_mse)
  if (model_air_test == "bart_two_stage")
    stopifnot(!is.null(fitted_air$stage1_diagnostics))
}
cat("Air tests passed: analytic online filtering, hidden/future-label isolation, missing-grid/reference guards, four-model posterior recovery.\n")

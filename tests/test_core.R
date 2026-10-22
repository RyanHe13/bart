source("R/ssm.R")
source("R/bart_adapter.R")
source("R/metrics.R")

assert_close <- function(x, y, tolerance, label) {
  if (max(abs(x - y)) > tolerance) stop(label, ": maximum error ", max(abs(x - y)))
}

# Independently construct the dense joint Gaussian law of all latent states,
# then condition directly on a mixture of observed/missing multivariate data.
set.seed(9021)
n <- 5L; k <- 2L; p <- 2L
A <- matrix(c(.7, -.1, .15, .6), 2L)
H <- matrix(c(1, .3, -.2, 1.2), 2L)
Q <- matrix(c(.2, .04, .04, .1), 2L)
R <- matrix(c(.3, .07, .07, .2), 2L)
m0 <- c(.2, -.3); P0 <- diag(c(.8, .6))
offset <- cbind(seq_len(n) * .03, rep(-.04, n))
observation_offset <- matrix(seq_len(n * p) * .01, n, p)
means <- matrix(0, n, k); covariance <- matrix(0, n * k, n * k)
index <- function(t) seq.int((t - 1L) * k + 1L, t * k)
last_mean <- m0; last_cov <- P0
for (tt in seq_len(n)) {
  means[tt, ] <- A %*% last_mean + offset[tt, ]
  covariance[index(tt), index(tt)] <- A %*% last_cov %*% t(A) + Q
  if (tt > 1L) for (ss in seq_len(tt - 1L)) {
    covariance[index(tt), index(ss)] <- A %*% covariance[index(tt - 1L), index(ss)]
    covariance[index(ss), index(tt)] <- t(covariance[index(tt), index(ss)])
  }
  last_mean <- means[tt, ]; last_cov <- covariance[index(tt), index(tt)]
}
bigH <- kronecker(diag(n), H); bigR <- kronecker(diag(n), R)
y <- matrix(c(.4, -.1, NA, .3, -.2, NA, NA, .8, .6, .1), n, p, byrow = TRUE)
yv <- as.vector(t(y)); cv <- as.vector(t(observation_offset)); mv <- as.vector(t(means))
seen <- which(!is.na(yv)); h <- bigH[seen, , drop = FALSE]
S <- h %*% covariance %*% t(h) + bigR[seen, seen, drop = FALSE]
gain <- covariance %*% t(h) %*% solve(S)
exact_mean <- mv + as.numeric(gain %*% (yv[seen] - cv[seen] - h %*% mv))
exact_cov <- covariance - gain %*% h %*% covariance
filtered <- kalman_filter(y, H, A, Q, R, offset, observation_offset, m0, P0)
samples <- replicate(12000L, as.vector(t(ffbs_sample(filtered))))
mcse <- sqrt(diag(exact_cov) / ncol(samples))
if (any(abs(rowMeans(samples) - exact_mean) > 6 * mcse + .002)) stop("FFBS mean disagrees with dense Gaussian conditioning")
assert_close(stats::cov(t(samples)), exact_cov, .025, "FFBS covariance")
assert_close(filtered$filtered_mean[n, ], tail(exact_mean, k), 1e-10, "Final filtered mean")

# Future observations cannot influence past filtered states, including when
# intervening entire observations are unavailable.
y_changed <- y; y_changed[4:5, ] <- 100
changed <- kalman_filter(y_changed, H, A, Q, R, offset, observation_offset, m0, P0)
assert_close(changed$filtered_mean[1:3, ], filtered$filtered_mean[1:3, ], 1e-12, "Filtering leakage")
all_missing <- kalman_filter(matrix(NA_real_, n, p), H, A, Q, R, offset, m0 = m0, P0 = P0)
assert_close(all_missing$filtered_mean, means, 1e-12, "Missing-data propagation")
stopifnot(all_missing$log_likelihood == 0)

# The scalar fast path must agree with the general time-varying implementation.
ys <- matrix(c(.3, NA, -.2, .1, .4), n, 1L)
fast <- kalman_filter(ys, matrix(1), matrix(.95), matrix(.02), matrix(.1), m0 = 0, P0 = matrix(.3))
slow <- kalman_filter(ys, rep(list(matrix(1)), n), matrix(.95), matrix(.02), matrix(.1), m0 = 0, P0 = matrix(.3))
assert_close(fast$filtered_mean, slow$filtered_mean, 1e-12, "Scalar filter means")
assert_close(fast$filtered_cov, slow$filtered_cov, 1e-12, "Scalar filter covariance")
assert_close(fast$log_lik, slow$log_lik, 1e-12, "Scalar filter likelihood")

if (.ssm_native_loaded) {
  # Exercise the actual native dispatch against both the independent matrix
  # implementation above and the preserved R scalar implementation. Random
  # normals have identical ordering, so paths can be compared directly.
  native_original_option <- getOption("bart.native")
  native_y <- matrix(c(.2, NA, -.4, .3, NA, NA, .1), ncol = 1L)
  native_d <- matrix(seq_len(7) * .02, ncol = 1L)
  native_c <- matrix(seq_len(7) * -.01, ncol = 1L)
  options(bart.native = FALSE)
  reference <- kalman_filter(native_y, matrix(.8), matrix(.94), matrix(.03), matrix(.2),
                              native_d, native_c, m0 = .3, P0 = matrix(.5))
  set.seed(165); reference_draw <- ffbs_sample(reference)
  options(bart.native = TRUE)
  accelerated <- kalman_filter(native_y, matrix(.8), matrix(.94), matrix(.03), matrix(.2),
                                native_d, native_c, m0 = .3, P0 = matrix(.5))
  set.seed(165); accelerated_draw <- ffbs_sample(accelerated)
  for (field in names(reference)) assert_close(reference[[field]], accelerated[[field]], 1e-12, paste("Native scalar", field))
  assert_close(reference_draw, accelerated_draw, 1e-12, "Native FFBS RNG/path parity")
  native_future <- native_y; native_future[6:7, 1L] <- 90
  native_changed <- kalman_filter(native_future, matrix(.8), matrix(.94), matrix(.03), matrix(.2),
                                   native_d, native_c, m0 = .3, P0 = matrix(.5))
  assert_close(accelerated$filtered_mean[1:5, ], native_changed$filtered_mean[1:5, ], 1e-12, "Native no future leakage")
  native_missing <- kalman_filter(matrix(NA_real_, 7L, 1L), matrix(1), matrix(.9), matrix(.1), matrix(.3), m0 = .4, P0 = matrix(.2))
  assert_close(native_missing$filtered_mean[, 1L], .4 * .9^seq_len(7L), 1e-12, "Native all-missing propagation")
  options(bart.native = native_original_option)
}

# CRPS has an exact finite-sample pairwise definition; do not validate it only
# against the same sorted-sample implementation.
z <- c(-1, .2, 1.1, 2)
direct_crps <- mean(abs(z - .4)) - .5 * mean(abs(outer(z, z, "-")))
assert_close(crps_sample(.4, z), direct_crps, 1e-12, "CRPS")
sc <- score_predictions(c(.4, NA), rbind(z, z))
stopifnot(sc$n == 1L, is.finite(sc$crps), sc$width95 >= sc$width80)

if (!requireNamespace("dbarts", quietly = TRUE)) stop("dbarts missing: conditional sampler test is required")
set.seed(734)
x <- matrix(seq(-1, 1, length.out = 40L), ncol = 1L)
anchor <- sin(3 * x[, 1L]) + rnorm(40L, sd = .2)
adapter <- bart_create(x, anchor, x_test = x, trees = 12L, seed = 734L, sigma = .3)
for (ii in seq_len(30L)) out <- bart_step(adapter, anchor)
# Training and test inputs are identical. After a large changing pseudo-response
# offset, returned tree predictions must still agree, ruling out double offsets.
for (ii in seq_len(30L)) {
  response <- anchor + .2 * sin(ii / 4) + .1 * x[, 1L]
  out <- bart_step(adapter, response)
  assert_close(out$f_train, out$f_test, 1e-10, "BART offset/prediction parity")
}
stopifnot(adapter$steps == 60L, identical(adapter$anchor, as.numeric(anchor)),
          identical(adapter$anchor_range, range(anchor)), is.finite(out$sigma), out$sigma > 0)
assert_close(adapter$sampler$data@y, anchor, 0, "BART anchor mutation")

# Pausing after each sweep must preserve precisely the same Markov chain as
# one uninterrupted dbarts run. This catches accidentally recreated samplers.
set.seed(151)
chunked <- bart_create(x, anchor, x_test = x, trees = 12L, seed = 151L, sigma = .3)
chunked_draws <- replicate(10L, bart_step(chunked, anchor)$f_train)
set.seed(151)
continuous <- bart_create(x, anchor, x_test = x, trees = 12L, seed = 151L, sigma = .3)
continuous_draws <- continuous$sampler$run(numBurnIn = 0L, numSamples = 10L, updateState = FALSE)$train
assert_close(chunked_draws, as.matrix(continuous_draws), 0, "BART pause/resume")
updated_test <- bart_step(chunked, anchor, x_test = x * 1.5)
stopifnot(length(updated_test$f_test) == nrow(x), all(is.finite(updated_test$f_test)))

# Independent chains with a strong location shift must fail diagnostics.
if (requireNamespace("posterior", quietly = TRUE)) {
  good <- array(rnorm(1000 * 4), c(1000, 4, 1), dimnames = list(NULL, NULL, "theta"))
  bad <- good; bad[, 1L, 1L] <- bad[, 1L, 1L] + 5
  stopifnot(!diagnose_chains(bad)$passed)
  stopifnot(diagnose_chains(good)$passed)
}
cat("Core checks passed: dense-Gaussian FFBS moments, missing data, no future leakage, scalar parity, CRPS, persistent BART offsets, chain diagnostics.\n")

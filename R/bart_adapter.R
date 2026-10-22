# A persistent conditional dbarts kernel. setResponse() is deliberately not
# used: it recalibrates the response scale and therefore the tree prior.

bart_create <- function(x, y_anchor, x_test = NULL, trees = 50L, seed = 1L,
                        sigma = NULL, k = 2, resid_df = 3, resid_quant = 0.90) {
  if (!requireNamespace("dbarts", quietly = TRUE)) stop("Install the pinned dbarts package first")
  x <- as.matrix(x); y_anchor <- as.numeric(y_anchor)
  if (!is.numeric(x) || any(!is.finite(x)) || nrow(x) != length(y_anchor) ||
      length(y_anchor) < 2L || any(!is.finite(y_anchor))) stop("Invalid BART training data")
  storage.mode(x) <- "double"
  if (diff(range(y_anchor)) <= 0) stop("BART anchor must have a fixed nonzero range")
  if (!is.null(x_test)) {
    x_test <- as.matrix(x_test)
    if (ncol(x_test) != ncol(x) || any(!is.finite(x_test))) stop("Invalid BART test design")
    storage.mode(x_test) <- "double"
  }
  if (is.null(sigma)) {
    fit <- stats::lm.fit(cbind(1, x), y_anchor)
    sigma <- sqrt(sum(fit$residuals^2) / max(1, nrow(x) - fit$rank))
    sigma <- max(sigma, stats::sd(y_anchor) * 0.05, 1e-8)
  }
  if (length(sigma) != 1L || !is.finite(sigma) || sigma <= 0) stop("sigma must be positive")
  if (resid_df <= 0 || resid_quant <= 0 || resid_quant >= 1 || k <= 0) stop("Invalid BART prior settings")
  control <- dbarts::dbartsControl(n.samples = 1L, n.burn = 0L,
                                  n.trees = as.integer(trees), n.chains = 1L,
                                  n.threads = 1L, n.thin = 1L, verbose = FALSE,
                                  keepTrainingFits = TRUE, keepTrees = FALSE,
                                  rngSeed = as.integer(seed), updateState = FALSE)
  sampler <- dbarts::dbarts(x, y_anchor, test = x_test,
                           offset = rep(0, nrow(x)),
                           offset.test = if (is.null(x_test)) NULL else rep(0, nrow(x_test)),
                           sigma = sigma, node.prior = normal(k),
                           resid.prior = chisq(resid_df, resid_quant),
                           control = control)
  adapter <- new.env(parent = emptyenv())
  adapter$sampler <- sampler; adapter$anchor <- y_anchor; adapter$x <- x
  adapter$x_test <- x_test; adapter$offset <- rep(0, nrow(x))
  adapter$steps <- 0L; adapter$initial_sigma <- sigma
  adapter$resid_prior_shape <- resid_df / 2
  adapter$resid_prior_rate <- 0.5 * sigma^2 * stats::qchisq(1 - resid_quant, resid_df)
  adapter$anchor_range <- range(y_anchor)
  class(adapter) <- "bart_conditional_adapter"
  adapter
}

bart_step <- function(adapter, response, x_test = NULL) {
  if (!inherits(adapter, "bart_conditional_adapter")) stop("Invalid BART adapter")
  response <- as.numeric(response)
  if (length(response) != length(adapter$anchor) || any(!is.finite(response))) stop("Invalid conditional response")
  if (!is.null(x_test)) {
    x_test <- as.matrix(x_test)
    if (is.null(adapter$x_test) || !identical(dim(x_test), dim(adapter$x_test)) ||
        any(!is.finite(x_test))) stop("Test design must keep its creation-time dimensions")
    storage.mode(x_test) <- "double"
    adapter$sampler$setTestPredictor(x_test)
    adapter$sampler$setTestOffset(rep(0, nrow(x_test)))
    adapter$x_test <- x_test
  }
  adapter$offset <- adapter$anchor - response
  adapter$sampler$setOffset(adapter$offset, updateScale = FALSE, updateState = FALSE)
  # Changing the training offset must never inject pseudo-responses into test
  # predictions. Both dimensions and test offsets are explicit at creation.
  if (!is.null(adapter$x_test)) adapter$sampler$setTestOffset(rep(0, nrow(adapter$x_test)))
  sample <- adapter$sampler$run(numBurnIn = 0L, numSamples = 1L, updateState = FALSE)
  adapter$steps <- adapter$steps + 1L
  result <- list(f_train = as.numeric(sample$train) - adapter$offset,
                 f_test = if (is.null(adapter$x_test)) NULL else as.numeric(sample$test),
                 sigma = as.numeric(sample$sigma))
  if (length(result$f_train) != nrow(adapter$x) || length(result$sigma) != 1L ||
      any(!is.finite(unlist(result))) || result$sigma <= 0) stop("Invalid BART sampler output")
  result
}

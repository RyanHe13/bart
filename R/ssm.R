# Linear Gaussian state space utilities. m0/P0 describe x_0; transition t
# produces x_t, followed by observation y_t. Missing observation components
# are integrated out, never filled with future observations.

.ssm_sym <- function(x) (x + t(x)) / 2

.ssm_matrix <- function(x, nr, nc, name) {
  x <- as.matrix(x)
  if (!identical(dim(x), c(as.integer(nr), as.integer(nc))) ||
      any(!is.finite(x))) stop(name, " has invalid dimensions or values")
  x
}

.ssm_series <- function(x, nr, nc, n, name) {
  if (is.list(x)) {
    if (length(x) != n) stop(name, " list must have one matrix per time")
    lapply(x, .ssm_matrix, nr = nr, nc = nc, name = name)
  } else {
    rep(list(.ssm_matrix(x, nr, nc, name)), n)
  }
}

.ssm_offset <- function(x, n, d, name) {
  if (is.null(x)) return(matrix(0, n, d))
  .ssm_matrix(x, n, d, name)
}

.ssm_chol_solve <- function(ch, b) backsolve(ch, forwardsolve(t(ch), b))

.ssm_draw <- function(mu, covariance) {
  covariance <- .ssm_sym(covariance)
  ch <- tryCatch(chol(covariance), error = function(e) NULL)
  if (!is.null(ch)) return(as.numeric(mu + t(ch) %*% rnorm(length(mu))))
  eig <- eigen(covariance, symmetric = TRUE)
  tolerance <- 1e-9 * max(1, max(abs(eig$values)))
  if (min(eig$values) < -tolerance) stop("Gaussian covariance is not positive semidefinite")
  as.numeric(mu + eig$vectors %*% (sqrt(pmax(eig$values, 0)) * rnorm(length(mu))))
}

kalman_filter <- function(y, H, A, Q, R, state_offset = NULL,
                          observation_offset = NULL, m0 = NULL, P0 = NULL) {
  y <- as.matrix(y)
  if (!is.numeric(y) || nrow(y) < 1L || any(is.infinite(y))) stop("y must be a nonempty numeric matrix, with NA for missing values")
  n <- nrow(y); p <- ncol(y)
  first_H <- if (is.list(H)) H[[1L]] else H
  k <- ncol(as.matrix(first_H))
  if (is.null(m0)) m0 <- rep(0, k)
  if (length(m0) != k || any(!is.finite(m0))) stop("m0 is invalid")
  if (is.null(P0)) P0 <- diag(1e4, k)
  P0 <- .ssm_matrix(P0, k, k, "P0")
  d <- .ssm_offset(state_offset, n, k, "state_offset")
  c <- .ssm_offset(observation_offset, n, p, "observation_offset")
  scalar <- p == 1L && k == 1L &&
    !any(vapply(list(H, A, Q, R), is.list, logical(1)))
  hs <- .ssm_series(H, p, k, n, "H")
  aa <- .ssm_series(A, k, k, n, "A")
  qq <- .ssm_series(Q, k, k, n, "Q")
  rr <- .ssm_series(R, p, p, n, "R")
  predicted_mean <- filtered_mean <- matrix(NA_real_, n, k)
  predicted_cov <- filtered_cov <- transitions <- array(NA_real_, c(k, k, n))
  log_lik <- numeric(n)

  if (scalar) {
    h <- hs[[1L]][1L]; a <- aa[[1L]][1L]
    q <- qq[[1L]][1L]; r <- rr[[1L]][1L]
    if (q < 0 || r < 0 || P0[1L] < 0) stop("Negative scalar variance")
    m <- as.numeric(m0); P <- as.numeric(P0)
    for (tt in seq_len(n)) {
      mp <- a * m + d[tt, 1L]; pp <- a * a * P + q
      predicted_mean[tt, 1L] <- mp; predicted_cov[1L, 1L, tt] <- pp
      transitions[1L, 1L, tt] <- a
      if (is.na(y[tt, 1L])) { m <- mp; P <- pp } else {
        innovation <- y[tt, 1L] - c[tt, 1L] - h * mp
        S <- h * h * pp + r
        if (!is.finite(S) || S <= 0) stop("Singular observation innovation variance")
        gain <- pp * h / S
        m <- mp + gain * innovation
        P <- (1 - gain * h)^2 * pp + gain^2 * r
        log_lik[tt] <- -0.5 * (log(2 * pi) + log(S) + innovation^2 / S)
      }
      filtered_mean[tt, 1L] <- m; filtered_cov[1L, 1L, tt] <- P
    }
  } else {
    m <- as.numeric(m0); P <- P0; ident <- diag(k)
    for (tt in seq_len(n)) {
      at <- aa[[tt]]
      mp <- as.numeric(at %*% m + d[tt, ])
      pp <- .ssm_sym(at %*% P %*% t(at) + qq[[tt]])
      predicted_mean[tt, ] <- mp; predicted_cov[, , tt] <- pp
      transitions[, , tt] <- at
      observed <- which(!is.na(y[tt, ]))
      if (!length(observed)) { m <- mp; P <- pp } else {
        ht <- hs[[tt]][observed, , drop = FALSE]
        rt <- rr[[tt]][observed, observed, drop = FALSE]
        innovation <- y[tt, observed] - c[tt, observed] - as.numeric(ht %*% mp)
        S <- .ssm_sym(ht %*% pp %*% t(ht) + rt)
        ch <- chol(S)
        gain <- t(.ssm_chol_solve(ch, ht %*% pp))
        m <- as.numeric(mp + gain %*% innovation)
        ikh <- ident - gain %*% ht
        P <- .ssm_sym(ikh %*% pp %*% t(ikh) + gain %*% rt %*% t(gain))
        whitened <- forwardsolve(t(ch), innovation)
        log_lik[tt] <- -0.5 * (length(observed) * log(2 * pi) +
                               2 * sum(log(diag(ch))) + sum(whitened^2))
      }
      filtered_mean[tt, ] <- m; filtered_cov[, , tt] <- P
    }
  }
  structure(list(predicted_mean = predicted_mean, filtered_mean = filtered_mean,
                 predicted_cov = predicted_cov, filtered_cov = filtered_cov,
                 transitions = transitions, log_lik = log_lik,
                 log_likelihood = sum(log_lik)), class = "bart_ssm_filter")
}

ffbs_sample <- function(filter) {
  if (!inherits(filter, "bart_ssm_filter")) stop("filter must be returned by kalman_filter")
  n <- nrow(filter$filtered_mean); k <- ncol(filter$filtered_mean)
  draw <- matrix(NA_real_, n, k)
  if (k == 1L) {
    z <- rnorm(n)
    draw[n, 1L] <- filter$filtered_mean[n, 1L] + sqrt(max(0, filter$filtered_cov[1L, 1L, n])) * z[n]
    if (n > 1L) for (tt in seq.int(n - 1L, 1L)) {
      P <- filter$predicted_cov[1L, 1L, tt + 1L]
      if (P <= 0) stop("FFBS requires nonsingular predicted state covariance")
      J <- filter$filtered_cov[1L, 1L, tt] * filter$transitions[1L, 1L, tt + 1L] / P
      v <- filter$filtered_cov[1L, 1L, tt] - J * J * P
      if (v < -1e-9 * max(1, filter$filtered_cov[1L, 1L, tt])) stop("Invalid FFBS conditional variance")
      mu <- filter$filtered_mean[tt, 1L] + J * (draw[tt + 1L, 1L] - filter$predicted_mean[tt + 1L, 1L])
      draw[tt, 1L] <- mu + sqrt(max(0, v)) * z[tt]
    }
    return(draw)
  }
  draw[n, ] <- .ssm_draw(filter$filtered_mean[n, ], matrix(filter$filtered_cov[, , n], k, k))
  if (n > 1L) for (tt in seq.int(n - 1L, 1L)) {
    C <- matrix(filter$filtered_cov[, , tt], k, k)
    P <- matrix(filter$predicted_cov[, , tt + 1L], k, k)
    at <- matrix(filter$transitions[, , tt + 1L], k, k)
    J <- t(.ssm_chol_solve(chol(.ssm_sym(P)), at %*% C))
    mu <- filter$filtered_mean[tt, ] + as.numeric(J %*% (draw[tt + 1L, ] - filter$predicted_mean[tt + 1L, ]))
    draw[tt, ] <- .ssm_draw(mu, C - J %*% P %*% t(J))
  }
  draw
}

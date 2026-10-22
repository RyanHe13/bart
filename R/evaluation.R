# Artificial outages use a full day between blocks for observable recalibration.
# Eligibility uses label availability only, never the measured label values.
make_gap_mask <- function(y, x, hours, max_blocks, minimum = .8, recovery_hours = 24L) {
  n <- length(y)
  stopifnot(nrow(as.matrix(x)) == n, hours > 0L, max_blocks > 0L, recovery_hours >= 1L)
  valid_x <- apply(is.finite(as.matrix(x)), 1L, all)
  blocked <- rep(FALSE, n); blocks <- integer(n); selected <- 0L; last_end <- 0L
  for (start in seq.int(1L, n, by = 24L)) {
    end <- start + hours - 1L
    if (end > n || selected >= max_blocks) break
    if (last_end > 0L) {
      if (start <= last_end + recovery_hours) next
      recovery <- seq.int(last_end + 1L, start - 1L)
      if (!any(is.finite(y[recovery]) & valid_x[recovery])) next
    }
    ids <- start:end
    if (any(blocked[ids]) || !all(valid_x[ids]) || mean(is.finite(y[ids])) < minimum) next
    selected <- selected + 1L
    blocked[ids] <- TRUE; blocks[ids] <- selected; last_end <- end
  }
  if (!selected) stop("No eligible reference-outage blocks")
  list(reference_allowed = !blocked, score = blocked & is.finite(y) & valid_x, blocks = blocks)
}

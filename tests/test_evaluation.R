for (gap in c(24L, 72L, 168L)) {
  y <- seq_len(1500)
  mask <- make_gap_mask(y, matrix(1, 1500, 2), gap, max_blocks = 3)
  runs <- rle(!mask$reference_allowed)
  stopifnot(all(runs$lengths[runs$values] == gap), sum(runs$values) == 3L)
  for (block in 2:3) {
    previous <- max(which(mask$blocks == block - 1L))
    current <- min(which(mask$blocks == block))
    stopifnot(current - previous - 1L >= 24L,
              any(mask$reference_allowed[seq.int(previous + 1L, current - 1L)]))
  }
  changed <- make_gap_mask(-100 * y, matrix(1, 1500, 2), gap, max_blocks = 3)
  stopifnot(identical(mask, changed))
}
cat("Outage length, recovery, and value-independent selection checks passed.\n")

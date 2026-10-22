if (!exists("diagnose_prediction_draws")) source("R/metrics.R")
if (!requireNamespace("posterior", quietly = TRUE)) stop("posterior is required for prediction diagnostics")

# Construct chains independently of the helper's reshape operation. One
# predictive location deliberately has an inconsistent chain mean; treating
# chain-major columns as interleaved samples would hide this failure.
set.seed(1920)
prediction_test_array <- array(stats::rnorm(600L * 4L * 2L), c(600L, 4L, 2L),
  dimnames = list(NULL, NULL, c("prediction_good", "prediction_bad")))
prediction_test_array[, 2L, 2L] <- prediction_test_array[, 2L, 2L] + 4
prediction_test_matrix <- rbind(as.vector(prediction_test_array[, , 1L]),
                               rep(NA_real_, 2400L),
                               as.vector(prediction_test_array[, , 2L]))
prediction_test_result <- diagnose_prediction_draws(prediction_test_matrix,
  draws_per_chain = 600L, chains = 4L, labels = c("good", "missing", "bad"))
prediction_test_direct <- diagnose_chains(prediction_test_array)
stopifnot(identical(prediction_test_result$variable,
                    c("prediction_good", "prediction_bad")),
          isTRUE(prediction_test_result$passed[1L]),
          !prediction_test_result$passed[2L],
          prediction_test_result$rhat[2L] > 1.1)
for (prediction_test_metric in c("rhat", "ess_bulk", "ess_tail"))
  stopifnot(max(abs(prediction_test_result[[prediction_test_metric]] -
                    prediction_test_direct[[prediction_test_metric]])) < 1e-10)
prediction_test_missing <- diagnose_prediction_draws(matrix(NA_real_, 2L, 2400L),
                                                       600L, 4L)
stopifnot(!prediction_test_missing$passed, is.na(prediction_test_missing$rhat))
prediction_test_selected <- diagnose_prediction_draws(prediction_test_matrix,
  600L, 4L, labels = c("good", "missing", "bad"), positions = c(2L, 3L))
stopifnot(identical(prediction_test_selected$variable, "prediction_bad"))
stopifnot(inherits(try(diagnose_prediction_draws(prediction_test_matrix,
                                               600L, 3L), silent = TRUE), "try-error"))
cat("Predictive diagnostic tests passed: chain-major reconstruction, missing rows, explicit selection, and inconsistent forecast chains.\n")

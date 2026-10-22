options(warn = 1)
for (file in c("R/ssm.R", "R/bart_adapter.R", "R/metrics.R", "R/evaluation.R", "R/yield.R", "R/air.R")) source(file)
for (file in sort(list.files("tests", pattern = "^test_.*\\.R$", full.names = TRUE))) {
  cat("\nRunning", file, "\n")
  source(file)
}
cat("\nAll R checks completed.\n")

/* Scalar Gaussian filtering/backward sampling. The R implementation remains
 * the reference and fallback. Random normals are supplied by R so enabling
 * this backend preserves the caller's RNG ordering. */
#include <R.h>
#include <Rinternals.h>
#include <Rmath.h>
#include <R_ext/Rdynload.h>
#include <math.h>
#include <limits.h>

static SEXP scalar_cov_array(R_xlen_t n) {
    SEXP out = PROTECT(allocVector(REALSXP, n));
    SEXP dims = PROTECT(allocVector(INTSXP, 3));
    INTEGER(dims)[0] = 1; INTEGER(dims)[1] = 1; INTEGER(dims)[2] = (int)n;
    setAttrib(out, R_DimSymbol, dims);
    UNPROTECT(2);
    return out;
}

SEXP bart_ssm_scalar_filter(SEXP y, SEXP coefficients, SEXP state_offset,
                            SEXP observation_offset, SEXP initial) {
    R_xlen_t n = XLENGTH(y);
    if (TYPEOF(y) != REALSXP || TYPEOF(coefficients) != REALSXP ||
        TYPEOF(state_offset) != REALSXP || TYPEOF(observation_offset) != REALSXP ||
        TYPEOF(initial) != REALSXP || XLENGTH(coefficients) != 4 ||
        XLENGTH(initial) != 2 || XLENGTH(state_offset) != n ||
        XLENGTH(observation_offset) != n || n < 1 || n > INT_MAX)
        error("Invalid native scalar filter input");
    double h = REAL(coefficients)[0], a = REAL(coefficients)[1];
    double q = REAL(coefficients)[2], r = REAL(coefficients)[3];
    double m = REAL(initial)[0], P = REAL(initial)[1];
    if (!R_FINITE(h) || !R_FINITE(a) || !R_FINITE(q) || !R_FINITE(r) ||
        !R_FINITE(m) || !R_FINITE(P) || q < 0 || r < 0 || P < 0)
        error("Invalid scalar filter parameters");
    SEXP result = PROTECT(allocVector(VECSXP, 7));
    SEXP names = PROTECT(allocVector(STRSXP, 7));
    const char *labels[] = {"predicted_mean", "filtered_mean", "predicted_cov",
                           "filtered_cov", "transitions", "log_lik", "log_likelihood"};
    for (int j = 0; j < 7; ++j) SET_STRING_ELT(names, j, mkChar(labels[j]));
    setAttrib(result, R_NamesSymbol, names);
    SET_VECTOR_ELT(result, 0, allocMatrix(REALSXP, (int)n, 1));
    SET_VECTOR_ELT(result, 1, allocMatrix(REALSXP, (int)n, 1));
    SET_VECTOR_ELT(result, 2, scalar_cov_array(n));
    SET_VECTOR_ELT(result, 3, scalar_cov_array(n));
    SET_VECTOR_ELT(result, 4, scalar_cov_array(n));
    SET_VECTOR_ELT(result, 5, allocVector(REALSXP, n));
    SET_VECTOR_ELT(result, 6, allocVector(REALSXP, 1));
    double *pm = REAL(VECTOR_ELT(result, 0)), *fm = REAL(VECTOR_ELT(result, 1));
    double *pc = REAL(VECTOR_ELT(result, 2)), *fc = REAL(VECTOR_ELT(result, 3));
    double *at = REAL(VECTOR_ELT(result, 4)), *ll = REAL(VECTOR_ELT(result, 5));
    const double *yy = REAL(y), *dd = REAL(state_offset), *cc = REAL(observation_offset);
    double total = 0;
    for (R_xlen_t t = 0; t < n; ++t) {
        if ((t & 4095) == 0) R_CheckUserInterrupt();
        if (!R_FINITE(dd[t]) || !R_FINITE(cc[t])) error("Nonfinite scalar offset");
        double mp = a * m + dd[t], pp = a * a * P + q;
        pm[t] = mp; pc[t] = pp; at[t] = a;
        if (ISNAN(yy[t])) { m = mp; P = pp; ll[t] = 0; }
        else {
            if (!R_FINITE(yy[t])) error("Infinite observation");
            double innovation = yy[t] - cc[t] - h * mp;
            double S = h * h * pp + r;
            if (!R_FINITE(S) || S <= 0) error("Singular observation innovation variance");
            double gain = pp * h / S;
            double complement = 1 - gain * h;
            m = mp + gain * innovation;
            P = complement * complement * pp + gain * gain * r;
            ll[t] = -0.5 * (log(2 * M_PI) + log(S) + innovation * innovation / S);
        }
        fm[t] = m; fc[t] = P; total += ll[t];
    }
    REAL(VECTOR_ELT(result, 6))[0] = total;
    SEXP cls = PROTECT(mkString("bart_ssm_filter"));
    classgets(result, cls);
    UNPROTECT(3);
    return result;
}

SEXP bart_ssm_scalar_ffbs(SEXP filtered_mean, SEXP predicted_mean,
                          SEXP filtered_cov, SEXP predicted_cov,
                          SEXP transitions, SEXP normals) {
    R_xlen_t n = XLENGTH(filtered_mean);
    if (n < 1 || n > INT_MAX || TYPEOF(filtered_mean) != REALSXP ||
        TYPEOF(predicted_mean) != REALSXP || TYPEOF(filtered_cov) != REALSXP ||
        TYPEOF(predicted_cov) != REALSXP || TYPEOF(transitions) != REALSXP ||
        TYPEOF(normals) != REALSXP || XLENGTH(predicted_mean) != n ||
        XLENGTH(filtered_cov) != n || XLENGTH(predicted_cov) != n ||
        XLENGTH(transitions) != n || XLENGTH(normals) != n)
        error("Invalid native scalar FFBS input");
    const double *fm = REAL(filtered_mean), *pm = REAL(predicted_mean);
    const double *fc = REAL(filtered_cov), *pc = REAL(predicted_cov);
    const double *aa = REAL(transitions), *z = REAL(normals);
    SEXP result = PROTECT(allocMatrix(REALSXP, (int)n, 1));
    double *draw = REAL(result);
    draw[n - 1] = fm[n - 1] + sqrt(fmax(0, fc[n - 1])) * z[n - 1];
    for (R_xlen_t t = n - 1; t > 0; ) {
        --t;
        if ((t & 4095) == 0) R_CheckUserInterrupt();
        double P = pc[t + 1];
        if (!R_FINITE(P) || P <= 0) error("FFBS requires nonsingular predicted state covariance");
        double J = fc[t] * aa[t + 1] / P;
        double variance = fc[t] - J * J * P;
        if (variance < -1e-9 * fmax(1, fc[t])) error("Invalid FFBS conditional variance");
        double mu = fm[t] + J * (draw[t + 1] - pm[t + 1]);
        draw[t] = mu + sqrt(fmax(0, variance)) * z[t];
    }
    UNPROTECT(1);
    return result;
}

static const R_CallMethodDef call_methods[] = {
    {"bart_ssm_scalar_filter", (DL_FUNC) &bart_ssm_scalar_filter, 5},
    {"bart_ssm_scalar_ffbs", (DL_FUNC) &bart_ssm_scalar_ffbs, 6},
    {NULL, NULL, 0}
};

void R_init_bartssm(DllInfo *dll) {
    R_registerRoutines(dll, NULL, call_methods, NULL, NULL);
    R_useDynamicSymbols(dll, FALSE);
}

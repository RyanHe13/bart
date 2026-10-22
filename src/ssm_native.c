/* Scalar Gaussian filtering/backward sampling. The R implementation remains
 * the reference and fallback. Random normals are supplied by R so enabling
 * this backend preserves the caller's RNG ordering. */
#include <R.h>
#include <Rinternals.h>
#include <Rmath.h>
#include <R_ext/Rdynload.h>
#include <R_ext/Lapack.h>
#include <math.h>
#include <limits.h>

#define BART_MAX_STATE 8

static double numeric_element(SEXP x, R_xlen_t i) {
    return TYPEOF(x) == REALSXP ? REAL(x)[i] :
           (INTEGER(x)[i] == NA_INTEGER ? NA_REAL : (double)INTEGER(x)[i]);
}

static int numeric_matrix(SEXP x, int rows, int columns) {
    SEXP dims = getAttrib(x, R_DimSymbol);
    return (TYPEOF(x) == REALSXP || TYPEOF(x) == INTSXP) &&
           TYPEOF(dims) == INTSXP && XLENGTH(dims) == 2 &&
           INTEGER(dims)[0] == rows && INTEGER(dims)[1] == columns;
}

/* Return false, and let the full R implementation handle the model, when a
 * matrix is not exactly diagonal. No near-zero correlations are discarded. */
static int diagonal_series(SEXP x, int k, int n, double *diagonals, int variance) {
    int listed = TYPEOF(x) == VECSXP;
    if (listed && XLENGTH(x) != n) return 0;
    int count = listed ? n : 1;
    for (int t = 0; t < count; ++t) {
        SEXP matrix = listed ? VECTOR_ELT(x, t) : x;
        if (!numeric_matrix(matrix, k, k)) return 0;
        for (int j = 0; j < k; ++j) for (int i = 0; i < k; ++i) {
            double value = numeric_element(matrix, i + k * j);
            if (!R_FINITE(value)) return 0;
            if (i != j && value != 0) return 0;
            if (i == j) {
                if (variance && value < 0) return 0;
                diagonals[t * k + i] = value;
            }
        }
    }
    if (!listed) for (int t = 1; t < n; ++t)
        for (int j = 0; j < k; ++j) diagonals[t * k + j] = diagonals[j];
    return 1;
}

static SEXP covariance_array(int k, int n) {
    SEXP out = PROTECT(allocVector(REALSXP, (R_xlen_t)k * k * n));
    SEXP dims = PROTECT(allocVector(INTSXP, 3));
    INTEGER(dims)[0] = k; INTEGER(dims)[1] = k; INTEGER(dims)[2] = n;
    setAttrib(out, R_DimSymbol, dims);
    UNPROTECT(2);
    return out;
}

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

/* Small-state filter for fixed H and independent observations, with exactly
 * diagonal transition/innovation matrices (possibly specified per time).
 * Each available measurement is assimilated by a Gaussian rank-one update;
 * Joseph covariance form maintains numerical stability for diffuse priors. */
SEXP bart_ssm_diagonal_filter(SEXP y, SEXP H, SEXP A, SEXP Q, SEXP R,
                              SEXP state_offset, SEXP observation_offset,
                              SEXP m0, SEXP P0) {
    SEXP yd = getAttrib(y, R_DimSymbol), hd = getAttrib(H, R_DimSymbol);
    if (XLENGTH(yd) != 2 || XLENGTH(hd) != 2) return R_NilValue;
    int n = INTEGER(yd)[0], p = INTEGER(yd)[1], k = INTEGER(hd)[1];
    if (n < 1 || k < 2 || k > BART_MAX_STATE || p < 1 || p > 64 ||
        !numeric_matrix(y, n, p) || !numeric_matrix(H, p, k) ||
        !numeric_matrix(R, p, p) || !numeric_matrix(P0, k, k) ||
        !numeric_matrix(state_offset, n, k) || !numeric_matrix(observation_offset, n, p) ||
        TYPEOF(m0) != REALSXP || XLENGTH(m0) != k) return R_NilValue;
    double *aa = (double *) R_alloc((size_t)n * k, sizeof(double));
    double *qq = (double *) R_alloc((size_t)n * k, sizeof(double));
    double *rr = (double *) R_alloc(p, sizeof(double));
    if (!diagonal_series(A, k, n, aa, 0) || !diagonal_series(Q, k, n, qq, 1) ||
        !diagonal_series(R, p, 1, rr, 1)) return R_NilValue;
    double m[BART_MAX_STATE], P[BART_MAX_STATE * BART_MAX_STATE];
    for (int i = 0; i < k; ++i) {
        m[i] = REAL(m0)[i];
        if (!R_FINITE(m[i])) error("Invalid initial state mean");
    }
    for (int j = 0; j < k; ++j) for (int i = 0; i < k; ++i) {
        P[i + k * j] = numeric_element(P0, i + k * j);
        if (!R_FINITE(P[i + k * j])) error("Invalid initial state covariance");
    }
    for (int j = 0; j < p * k; ++j) if (!R_FINITE(numeric_element(H, j)))
        error("Invalid observation loadings");
    SEXP result = PROTECT(allocVector(VECSXP, 7));
    SEXP names = PROTECT(allocVector(STRSXP, 7));
    const char *labels[] = {"predicted_mean", "filtered_mean", "predicted_cov",
                           "filtered_cov", "transitions", "log_lik", "log_likelihood"};
    for (int j = 0; j < 7; ++j) SET_STRING_ELT(names, j, mkChar(labels[j]));
    setAttrib(result, R_NamesSymbol, names);
    SET_VECTOR_ELT(result, 0, allocMatrix(REALSXP, n, k));
    SET_VECTOR_ELT(result, 1, allocMatrix(REALSXP, n, k));
    SET_VECTOR_ELT(result, 2, covariance_array(k, n));
    SET_VECTOR_ELT(result, 3, covariance_array(k, n));
    SET_VECTOR_ELT(result, 4, covariance_array(k, n));
    SET_VECTOR_ELT(result, 5, allocVector(REALSXP, n));
    SET_VECTOR_ELT(result, 6, allocVector(REALSXP, 1));
    double *pm = REAL(VECTOR_ELT(result, 0)), *fm = REAL(VECTOR_ELT(result, 1));
    double *pc = REAL(VECTOR_ELT(result, 2)), *fc = REAL(VECTOR_ELT(result, 3));
    double *at = REAL(VECTOR_ELT(result, 4)), *ll = REAL(VECTOR_ELT(result, 5));
    double pp[BART_MAX_STATE * BART_MAX_STATE], h[BART_MAX_STATE], gain[BART_MAX_STATE];
    double B[BART_MAX_STATE * BART_MAX_STATE], temp[BART_MAX_STATE * BART_MAX_STATE];
    double updated[BART_MAX_STATE * BART_MAX_STATE];
    double total = 0;
    for (int t = 0; t < n; ++t) {
        if ((t & 1023) == 0) R_CheckUserInterrupt();
        for (int i = 0; i < k; ++i) {
            double offset = numeric_element(state_offset, t + n * i);
            if (!R_FINITE(offset)) error("Invalid state offset");
            m[i] = aa[t * k + i] * m[i] + offset;
            pm[t + n * i] = m[i];
        }
        for (int j = 0; j < k; ++j) for (int i = 0; i < k; ++i) {
            int ij = i + k * j;
            pp[ij] = aa[t * k + i] * P[ij] * aa[t * k + j] + (i == j ? qq[t * k + i] : 0);
            pc[ij + k * k * t] = pp[ij];
            at[ij + k * k * t] = i == j ? aa[t * k + i] : 0;
        }
        double likelihood = 0;
        for (int obs = 0; obs < p; ++obs) {
            double value = numeric_element(y, t + n * obs);
            double offset = numeric_element(observation_offset, t + n * obs);
            if (!R_FINITE(offset)) error("Invalid observation offset");
            if (ISNAN(value)) continue;
            if (!R_FINITE(value)) error("Infinite observation");
            double innovation = value - offset, S = rr[obs];
            for (int i = 0; i < k; ++i) { h[i] = numeric_element(H, obs + p * i); innovation -= h[i] * m[i]; }
            for (int i = 0; i < k; ++i) {
                gain[i] = 0;
                for (int j = 0; j < k; ++j) gain[i] += pp[i + k * j] * h[j];
                S += h[i] * gain[i];
            }
            if (!R_FINITE(S) || S <= 0) error("Singular observation innovation variance");
            for (int i = 0; i < k; ++i) { gain[i] /= S; m[i] += gain[i] * innovation; }
            for (int j = 0; j < k; ++j) for (int i = 0; i < k; ++i) B[i + k * j] = (i == j ? 1.0 : 0.0) - gain[i] * h[j];
            for (int j = 0; j < k; ++j) for (int i = 0; i < k; ++i) {
                double v = 0;
                for (int l = 0; l < k; ++l) v += B[i + k * l] * pp[l + k * j];
                temp[i + k * j] = v;
            }
            for (int j = 0; j < k; ++j) for (int i = 0; i < k; ++i) {
                double v = rr[obs] * gain[i] * gain[j];
                for (int l = 0; l < k; ++l) v += temp[i + k * l] * B[j + k * l];
                updated[i + k * j] = v;
            }
            for (int j = 0; j < k; ++j) for (int i = 0; i < k; ++i) pp[i + k * j] = 0.5 * (updated[i + k * j] + updated[j + k * i]);
            likelihood += -0.5 * (log(2 * M_PI) + log(S) + innovation * innovation / S);
        }
        for (int i = 0; i < k; ++i) fm[t + n * i] = m[i];
        for (int j = 0; j < k * k; ++j) { P[j] = pp[j]; fc[j + k * k * t] = pp[j]; }
        ll[t] = likelihood; total += likelihood;
    }
    REAL(VECTOR_ELT(result, 6))[0] = total;
    SEXP cls = PROTECT(mkString("bart_ssm_filter")); classgets(result, cls);
    UNPROTECT(3);
    return result;
}

/* Exact small-matrix backward recursion. Cholesky uses the same LAPACK routine
 * as R's chol(). Return NULL on semidefinite cases so the R eigen fallback can
 * reuse these already generated normal draws without changing RNG state. */
SEXP bart_ssm_small_ffbs(SEXP filtered_mean, SEXP predicted_mean,
                        SEXP filtered_cov, SEXP predicted_cov,
                        SEXP transitions, SEXP normals) {
    SEXP dims = getAttrib(filtered_mean, R_DimSymbol);
    if (XLENGTH(dims) != 2) return R_NilValue;
    int n = INTEGER(dims)[0], k = INTEGER(dims)[1], kk = k * k;
    if (n < 1 || k < 2 || k > BART_MAX_STATE ||
        TYPEOF(filtered_mean) != REALSXP || TYPEOF(predicted_mean) != REALSXP ||
        TYPEOF(filtered_cov) != REALSXP || TYPEOF(predicted_cov) != REALSXP ||
        TYPEOF(transitions) != REALSXP || TYPEOF(normals) != REALSXP ||
        XLENGTH(predicted_mean) != (R_xlen_t)n * k ||
        XLENGTH(filtered_cov) != (R_xlen_t)n * kk || XLENGTH(predicted_cov) != (R_xlen_t)n * kk ||
        XLENGTH(transitions) != (R_xlen_t)n * kk || XLENGTH(normals) != (R_xlen_t)n * k) return R_NilValue;
    const double *fm = REAL(filtered_mean), *pm = REAL(predicted_mean);
    const double *fc = REAL(filtered_cov), *pc = REAL(predicted_cov), *aa = REAL(transitions), *z = REAL(normals);
    double cov[BART_MAX_STATE * BART_MAX_STATE], cholP[BART_MAX_STATE * BART_MAX_STATE];
    double rhs[BART_MAX_STATE * BART_MAX_STATE], J[BART_MAX_STATE * BART_MAX_STATE];
    double temp[BART_MAX_STATE * BART_MAX_STATE], mu[BART_MAX_STATE];
    SEXP result = PROTECT(allocMatrix(REALSXP, n, k));
    double *draw = REAL(result);
    for (int t = n - 1; t >= 0; --t) {
        if ((t & 1023) == 0) R_CheckUserInterrupt();
        const double *C = fc + t * kk;
        for (int i = 0; i < k; ++i) mu[i] = fm[t + n * i];
        if (t == n - 1) {
            for (int j = 0; j < k; ++j) for (int i = 0; i < k; ++i) cov[i + k * j] = 0.5 * (C[i + k * j] + C[j + k * i]);
        } else {
            const double *P = pc + (t + 1) * kk, *A = aa + (t + 1) * kk;
            for (int j = 0; j < k; ++j) for (int i = 0; i < k; ++i) {
                cholP[i + k * j] = 0.5 * (P[i + k * j] + P[j + k * i]);
                double v = 0;
                for (int l = 0; l < k; ++l) v += A[i + k * l] * C[l + k * j];
                rhs[i + k * j] = v;
            }
            int info = 0;
            F77_CALL(dpotrf)("U", &k, cholP, &k, &info FCONE);
            if (info != 0) { UNPROTECT(1); return R_NilValue; }
            F77_CALL(dpotrs)("U", &k, &k, cholP, &k, rhs, &k, &info FCONE);
            if (info != 0) { UNPROTECT(1); return R_NilValue; }
            for (int j = 0; j < k; ++j) for (int i = 0; i < k; ++i) J[i + k * j] = rhs[j + k * i];
            for (int i = 0; i < k; ++i) for (int j = 0; j < k; ++j) mu[i] += J[i + k * j] * (draw[t + 1 + n * j] - pm[t + 1 + n * j]);
            for (int j = 0; j < k; ++j) for (int i = 0; i < k; ++i) {
                double v = 0;
                for (int l = 0; l < k; ++l) v += J[i + k * l] * P[l + k * j];
                temp[i + k * j] = v;
            }
            for (int j = 0; j < k; ++j) for (int i = 0; i < k; ++i) {
                double v = C[i + k * j];
                for (int l = 0; l < k; ++l) v -= temp[i + k * l] * J[j + k * l];
                cov[i + k * j] = v;
            }
            for (int j = 0; j < k; ++j) for (int i = 0; i < j; ++i) {
                double v = 0.5 * (cov[i + k * j] + cov[j + k * i]); cov[i + k * j] = v; cov[j + k * i] = v;
            }
        }
        int info = 0;
        F77_CALL(dpotrf)("U", &k, cov, &k, &info FCONE);
        if (info != 0) { UNPROTECT(1); return R_NilValue; }
        for (int i = 0; i < k; ++i) {
            double value = mu[i];
            for (int j = 0; j <= i; ++j) value += cov[j + k * i] * z[(n - 1 - t) * k + j];
            draw[t + n * i] = value;
        }
    }
    UNPROTECT(1);
    return result;
}

static const R_CallMethodDef call_methods[] = {
    {"bart_ssm_scalar_filter", (DL_FUNC) &bart_ssm_scalar_filter, 5},
    {"bart_ssm_scalar_ffbs", (DL_FUNC) &bart_ssm_scalar_ffbs, 6},
    {"bart_ssm_diagonal_filter", (DL_FUNC) &bart_ssm_diagonal_filter, 9},
    {"bart_ssm_small_ffbs", (DL_FUNC) &bart_ssm_small_ffbs, 6},
    {NULL, NULL, 0}
};

void R_init_bartssm(DllInfo *dll) {
    R_registerRoutines(dll, NULL, call_methods, NULL, NULL);
    R_useDynamicSymbols(dll, FALSE);
}

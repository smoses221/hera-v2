/* kfblas: a whole Kalman filter step (predict + update, KF or EKF) in
 * one NIF call, on cblas/LAPACKE (netlib on GRiSP, OpenBLAS on the host).
 *
 * Why: blasmat makes one NIF call per matrix operation (~17 per step),
 * each allocating a result buffer and copying it back to Erlang. For
 * Hera's <= 9x9 matrices that fixed per-call cost dominates the maths.
 * Here all buffers live in one resource, allocated once by new/2, and
 * every step works in place: no malloc, no Erlang terms built (the
 * step functions return `ok`).
 *
 * Layout: every matrix is row-major. The only LAPACK input, S, is
 * symmetric, so row- and col-major coincide; for dpotrs the right-hand
 * side K (n x m, row-major) is read as col-major m x n = K^T, which is
 * exactly the system S K^T = (P H^T)^T that gives K = P H^T S^-1.
 * The LAPACKE *_work variants are used with LAPACK_COL_MAJOR, so
 * LAPACKE neither transposes nor allocates.
 *
 * Equations (same as kalman_bench:kf/7 and ekf/7, P symmetric):
 *   predict:  x = F x;  P = F P F^T + Q
 *   update:   PHt = P H^T;  S = H PHt + R;  K = PHt S^-1
 *             y = z - H x   (KF)   or   z - h(x)   (EKF, H = Jh(x))
 *             x = x + K y;  P = P - K PHt^T   (= P - K H P)
 *
 * A filter is mutable state: use it from one process only.
 *
 * Built statically into ERTS on GRiSP; with -DKFBLAS_DYNAMIC_NIF as a
 * host .so (c_src/Makefile). All symbols except kfblas_nif_init are
 * static, so it can't clash with numerl_nif.c or blas_nif.c.
 */
#ifndef KFBLAS_DYNAMIC_NIF
#define STATIC_ERLANG_NIF 1
#endif

#include "erl_nif.h"
#include <string.h>
#include <math.h>
#include <cblas.h>
#include <lapacke.h>

typedef struct {
    int n, mmax;
    double *x, *P, *F, *Q;      /* n, n*n, n*n, n*n */
    double *xp, *T;             /* n, n*n: predict scratch */
    double *H, *R, *z, *hx;     /* mmax*n, mmax*mmax, mmax, mmax: inputs */
    double *PHt, *K, *S, *y;    /* n*mmax, n*mmax, mmax*mmax, mmax */
    double *mem;                /* one block holding all of the above */
} kf_t;

static ErlNifResourceType *kf_type;
static ERL_NIF_TERM atom_ok, atom_error, atom_not_pos_def;

static void kf_dtor(ErlNifEnv *env, void *obj) {
    kf_t *kf = (kf_t *) obj;
    if (kf->mem) enif_free(kf->mem);
}

static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
    kf_type = enif_open_resource_type(env, NULL, "kfblas_filter", kf_dtor,
                                      ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER, NULL);
    atom_ok = enif_make_atom(env, "ok");
    atom_error = enif_make_atom(env, "error");
    atom_not_pos_def = enif_make_atom(env, "not_positive_definite");
    return kf_type == NULL;
}

static int upgrade(ErlNifEnv *env, void **priv, void **old_priv, ERL_NIF_TERM info) {
    return load(env, priv, info);
}

static int get_kf(ErlNifEnv *env, ERL_NIF_TERM t, kf_t **kf) {
    return enif_get_resource(env, t, kf_type, (void **) kf);
}

/* Copies a float64 binary of exactly `count` doubles into dst. Copying
 * (rather than pointing into the binary) keeps BLAS inputs aligned;
 * sub-binaries need not be, and ARM faults on unaligned doubles. */
static int get_doubles(ErlNifEnv *env, ERL_NIF_TERM t, double *dst, size_t count) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, t, &bin) || bin.size != count * sizeof(double))
        return 0;
    memcpy(dst, bin.data, bin.size);
    return 1;
}

/* Number of doubles in a binary, or -1. */
static int n_doubles(ErlNifEnv *env, ERL_NIF_TERM t) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, t, &bin) || bin.size % sizeof(double) != 0)
        return -1;
    return (int) (bin.size / sizeof(double));
}

static ERL_NIF_TERM make_doubles(ErlNifEnv *env, const double *src, size_t count) {
    ERL_NIF_TERM t;
    unsigned char *dst = enif_make_new_binary(env, count * sizeof(double), &t);
    memcpy(dst, src, count * sizeof(double));
    return t;
}

/* ---- maths --------------------------------------------------------- */

static void do_predict(kf_t *kf) {
    int n = kf->n;
    /* xp = F x;  x = xp */
    cblas_dgemv(CblasRowMajor, CblasNoTrans, n, n, 1.0, kf->F, n, kf->x, 1, 0.0, kf->xp, 1);
    memcpy(kf->x, kf->xp, n * sizeof(double));
    /* T = F P;  P = Q;  P = T F^T + P */
    cblas_dgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, n, n, n,
                1.0, kf->F, n, kf->P, n, 0.0, kf->T, n);
    memcpy(kf->P, kf->Q, n * n * sizeof(double));
    cblas_dgemm(CblasRowMajor, CblasNoTrans, CblasTrans, n, n, n,
                1.0, kf->T, n, kf->F, n, 1.0, kf->P, n);
}

/* Update with m measurements, from kf->H, kf->R, kf->z (already
 * filled). hx NULL: linear KF, y = z - H x. Otherwise EKF, y = z - hx.
 * Returns 0 on success, or the dpotrf info (S not positive definite). */
static int do_update(kf_t *kf, int m, const double *hx) {
    int n = kf->n, i;
    /* PHt = P H^T  (n x m) */
    cblas_dgemm(CblasRowMajor, CblasNoTrans, CblasTrans, n, m, n,
                1.0, kf->P, n, kf->H, n, 0.0, kf->PHt, m);
    /* S = R;  S = H PHt + S  (m x m) */
    memcpy(kf->S, kf->R, m * m * sizeof(double));
    cblas_dgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, m, m, n,
                1.0, kf->H, n, kf->PHt, m, 1.0, kf->S, m);
    /* y = z - H x   or   y = z - h(x) */
    if (hx == NULL) {
        memcpy(kf->y, kf->z, m * sizeof(double));
        cblas_dgemv(CblasRowMajor, CblasNoTrans, m, n, -1.0, kf->H, n, kf->x, 1, 1.0, kf->y, 1);
    } else {
        for (i = 0; i < m; i++) kf->y[i] = kf->z[i] - hx[i];
    }
    /* K = PHt S^-1 */
    memcpy(kf->K, kf->PHt, n * m * sizeof(double));
    if (m == 1) {
        cblas_dscal(n, 1.0 / kf->S[0], kf->K, 1);
    } else {
        lapack_int info = LAPACKE_dpotrf_work(LAPACK_COL_MAJOR, 'L', m, kf->S, m);
        if (info != 0) return (int) info;
        LAPACKE_dpotrs_work(LAPACK_COL_MAJOR, 'L', m, n, kf->S, m, kf->K, m);
    }
    /* x = x + K y */
    cblas_dgemv(CblasRowMajor, CblasNoTrans, n, m, 1.0, kf->K, m, kf->y, 1, 1.0, kf->x, 1);
    /* P = P - K PHt^T */
    cblas_dgemm(CblasRowMajor, CblasNoTrans, CblasTrans, n, n, m,
                -1.0, kf->K, m, kf->PHt, m, 1.0, kf->P, n);
    return 0;
}

static ERL_NIF_TERM update_result(ErlNifEnv *env, int info) {
    return info == 0 ? atom_ok : enif_make_tuple2(env, atom_error, atom_not_pos_def);
}

/* Reads H (m x n), R (m x m), Z (m) into the filter; m from Z's size. */
static int get_hrz(ErlNifEnv *env, kf_t *kf, ERL_NIF_TERM h, ERL_NIF_TERM r, ERL_NIF_TERM z, int *m) {
    *m = n_doubles(env, z);
    return *m >= 1 && *m <= kf->mmax
        && get_doubles(env, z, kf->z, *m)
        && get_doubles(env, h, kf->H, (size_t) *m * kf->n)
        && get_doubles(env, r, kf->R, (size_t) *m * *m);
}

/* ---- NIFs ---------------------------------------------------------- */

/* new(N, MaxM) -> Filter. x = 0, P = I, F = I, Q = 0. */
static ERL_NIF_TERM nif_new(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    int n, mmax, i;
    if (!enif_get_int(env, argv[0], &n) || !enif_get_int(env, argv[1], &mmax)
        || n < 1 || mmax < 1 || mmax > n)
        return enif_make_badarg(env);

    size_t total = (size_t) n                /* x */
                 + 3 * (size_t) n * n        /* P, F, Q */
                 + n + (size_t) n * n        /* xp, T */
                 + (size_t) mmax * n + (size_t) mmax * mmax + 2 * (size_t) mmax  /* H, R, z, hx */
                 + 2 * (size_t) n * mmax + (size_t) mmax * mmax + mmax;          /* PHt, K, S, y */

    kf_t *kf = enif_alloc_resource(kf_type, sizeof(kf_t));
    kf->mem = enif_alloc(total * sizeof(double));
    if (kf->mem == NULL) {
        enif_release_resource(kf);
        return enif_raise_exception(env, enif_make_atom(env, "enomem"));
    }
    memset(kf->mem, 0, total * sizeof(double));
    kf->n = n;
    kf->mmax = mmax;
    double *p = kf->mem;
    kf->x = p;   p += n;
    kf->P = p;   p += n * n;
    kf->F = p;   p += n * n;
    kf->Q = p;   p += n * n;
    kf->xp = p;  p += n;
    kf->T = p;   p += n * n;
    kf->H = p;   p += mmax * n;
    kf->R = p;   p += mmax * mmax;
    kf->z = p;   p += mmax;
    kf->hx = p;  p += mmax;
    kf->PHt = p; p += n * mmax;
    kf->K = p;   p += n * mmax;
    kf->S = p;   p += mmax * mmax;
    kf->y = p;
    for (i = 0; i < n; i++) {
        kf->P[i * n + i] = 1.0;
        kf->F[i * n + i] = 1.0;
    }

    ERL_NIF_TERM t = enif_make_resource(env, kf);
    enif_release_resource(kf);
    return t;
}

/* set_model(Filter, F, Q) -> ok */
static ERL_NIF_TERM nif_set_model(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    kf_t *kf;
    if (!get_kf(env, argv[0], &kf)
        || n_doubles(env, argv[1]) != kf->n * kf->n || n_doubles(env, argv[2]) != kf->n * kf->n)
        return enif_make_badarg(env);
    get_doubles(env, argv[1], kf->F, (size_t) kf->n * kf->n);
    get_doubles(env, argv[2], kf->Q, (size_t) kf->n * kf->n);
    return atom_ok;
}

/* set_state(Filter, X, P) -> ok */
static ERL_NIF_TERM nif_set_state(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    kf_t *kf;
    if (!get_kf(env, argv[0], &kf)
        || n_doubles(env, argv[1]) != kf->n || n_doubles(env, argv[2]) != kf->n * kf->n)
        return enif_make_badarg(env);
    get_doubles(env, argv[1], kf->x, kf->n);
    get_doubles(env, argv[2], kf->P, (size_t) kf->n * kf->n);
    return atom_ok;
}

/* get_state(Filter) -> {X, P} as float64 binaries (copies). */
static ERL_NIF_TERM nif_get_state(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    kf_t *kf;
    if (!get_kf(env, argv[0], &kf))
        return enif_make_badarg(env);
    return enif_make_tuple2(env, make_doubles(env, kf->x, kf->n),
                            make_doubles(env, kf->P, (size_t) kf->n * kf->n));
}

/* predict(Filter) -> ok */
static ERL_NIF_TERM nif_predict(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    kf_t *kf;
    if (!get_kf(env, argv[0], &kf))
        return enif_make_badarg(env);
    do_predict(kf);
    return atom_ok;
}

/* update(Filter, H, R, Z) -> ok | {error, not_positive_definite} */
static ERL_NIF_TERM nif_update(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    kf_t *kf;
    int m;
    if (!get_kf(env, argv[0], &kf) || !get_hrz(env, kf, argv[1], argv[2], argv[3], &m))
        return enif_make_badarg(env);
    return update_result(env, do_update(kf, m, NULL));
}

/* kf_step(Filter, H, R, Z): predict + linear update in one call. */
static ERL_NIF_TERM nif_kf_step(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    kf_t *kf;
    int m;
    if (!get_kf(env, argv[0], &kf) || !get_hrz(env, kf, argv[1], argv[2], argv[3], &m))
        return enif_make_badarg(env);
    do_predict(kf);
    return update_result(env, do_update(kf, m, NULL));
}

/* ekf_predict(Filter) -> Xp: predicts, then returns the predicted
 * state so Erlang can evaluate h(Xp) and its Jacobian. */
static ERL_NIF_TERM nif_ekf_predict(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    kf_t *kf;
    if (!get_kf(env, argv[0], &kf))
        return enif_make_badarg(env);
    do_predict(kf);
    return make_doubles(env, kf->x, kf->n);
}

/* ekf_update(Filter, Jh, Hx, R, Z) -> ok | {error, ...}:
 * update with Jacobian Jh (m x n) and h(Xp) = Hx (m). */
static ERL_NIF_TERM nif_ekf_update(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    kf_t *kf;
    int m;
    if (!get_kf(env, argv[0], &kf) || !get_hrz(env, kf, argv[1], argv[3], argv[4], &m)
        || !get_doubles(env, argv[2], kf->hx, m))
        return enif_make_badarg(env);
    return update_result(env, do_update(kf, m, kf->hx));
}

/* ekf_range_step(Filter, {Ix, Iy, Iz}, Anchor, R, Z): predict + EKF
 * update for one range z = |p - Anchor|, with the model in C (one
 * call, nothing built in Erlang). {Ix, Iy, Iz} are the 0-based
 * indices of the position in x; Anchor is 3 doubles, R and Z 1. */
static ERL_NIF_TERM nif_ekf_range_step(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    kf_t *kf;
    const ERL_NIF_TERM *idx_t;
    int arity, idx[3], i;
    double anchor[3], d[3], r;
    if (!get_kf(env, argv[0], &kf)
        || !enif_get_tuple(env, argv[1], &arity, &idx_t) || arity != 3
        || !get_doubles(env, argv[2], anchor, 3)
        || !get_doubles(env, argv[3], kf->R, 1)
        || !get_doubles(env, argv[4], kf->z, 1))
        return enif_make_badarg(env);
    for (i = 0; i < 3; i++)
        if (!enif_get_int(env, idx_t[i], &idx[i]) || idx[i] < 0 || idx[i] >= kf->n)
            return enif_make_badarg(env);

    do_predict(kf);
    for (i = 0; i < 3; i++) d[i] = kf->x[idx[i]] - anchor[i];
    r = sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
    if (r < 1.0e-6) r = 1.0e-6;   /* as bench_runner's MIN_RANGE */
    memset(kf->H, 0, kf->n * sizeof(double));
    for (i = 0; i < 3; i++) kf->H[idx[i]] = d[i] / r;
    kf->hx[0] = r;
    return update_result(env, do_update(kf, 1, kf->hx));
}

static ErlNifFunc nif_funcs[] = {
    {"new", 2, nif_new, 0},
    {"set_model", 3, nif_set_model, 0},
    {"set_state", 3, nif_set_state, 0},
    {"get_state", 1, nif_get_state, 0},
    {"predict", 1, nif_predict, 0},
    {"update", 4, nif_update, 0},
    {"kf_step", 4, nif_kf_step, 0},
    {"ekf_predict", 1, nif_ekf_predict, 0},
    {"ekf_update", 5, nif_ekf_update, 0},
    {"ekf_range_step", 5, nif_ekf_range_step, 0}
};

ERL_NIF_INIT(kfblas, nif_funcs, load, NULL, upgrade, NULL)

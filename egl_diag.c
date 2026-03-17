/*
 * egl_diag.c - LD_PRELOAD diagnostic for GTK4 GL renderer on EGL/Wayland
 *
 * Chain: GTK4 → libepoxy → dlsym(dlopen("libEGL.so.1"), "eglGetProcAddress")
 *                         → eglGetProcAddress("eglSwapBuffersWithDamageKHR")
 *
 * Epoxy uses dlsym with a specific library handle, bypassing normal
 * LD_PRELOAD interception. We intercept dlsym itself (bootstrapped via
 * dlvsym to avoid recursion) to inject our EGL wrappers.
 *
 * Build: gcc -shared -fPIC -o egl_diag.so egl_diag.c -ldl
 * Use:   GSK_RENDERER=gl LD_PRELOAD=/path/to/egl_diag.so app
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <EGL/egl.h>
#include <string.h>
#include <stdio.h>
#include <time.h>
#include <stdint.h>

#define LOG(fmt, ...) fprintf(stderr, "[egl_diag] " fmt "\n", ##__VA_ARGS__)

static inline double now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1000000.0;
}

/* ── frame timing state ──────────────────────────────────────────── */

static double   last_ms     = 0;
static uint64_t frame_count = 0;
static uint64_t err_count   = 0;
static double   min_delta   = 1e9;
static double   max_delta   = 0;
static double   sum_delta   = 0;

static void log_frame(double t0, double t1, int ok, const char *fn)
{
    double delta = (last_ms > 0) ? (t0 - last_ms) : 0;
    double dur   = t1 - t0;
    frame_count++;

    if (!ok) err_count++;

    if (frame_count > 1) {
        if (delta < min_delta) min_delta = delta;
        if (delta > max_delta) max_delta = delta;
        sum_delta += delta;
    }

    int jitter = (frame_count > 2 && (delta < 4.0 || delta > 50.0));
    LOG("%s #%lu: d=%.1f dur=%.1f%s",
        fn, (unsigned long)frame_count, delta, dur,
        jitter ? " [J]" : "");

    if (frame_count % 300 == 0 && frame_count > 1) {
        double avg = sum_delta / (frame_count - 1);
        LOG("Stats: %lu frames, %lu err, "
            "delta min=%.1f avg=%.1f max=%.1f jitter=%.1fms",
            (unsigned long)frame_count, (unsigned long)err_count,
            min_delta, avg, max_delta, max_delta - min_delta);
    }

    last_ms = t0;
}

/* ── real function pointers ──────────────────────────────────────── */

typedef EGLBoolean (*PFN_eglSwapBuffers)(EGLDisplay, EGLSurface);
typedef EGLBoolean (*PFN_eglSwapBuffersWithDamage)(
    EGLDisplay, EGLSurface, const EGLint *, EGLint);
typedef EGLBoolean (*PFN_eglSwapInterval)(EGLDisplay, EGLint);
typedef void      *(*PFN_eglGetProcAddress)(const char *);

static PFN_eglSwapBuffers             real_swap          = NULL;
static PFN_eglSwapBuffersWithDamage   real_swap_damage   = NULL;
static PFN_eglSwapInterval            real_swap_interval = NULL;
static PFN_eglGetProcAddress          real_getProcAddr   = NULL;

/* ── wrappers ────────────────────────────────────────────────────── */

static EGLBoolean wrap_swap(EGLDisplay dpy, EGLSurface surf)
{
    double t0 = now_ms();
    EGLBoolean r = real_swap(dpy, surf);
    log_frame(t0, now_ms(), r, "Swap");
    return r;
}

static EGLBoolean wrap_swap_damage(
    EGLDisplay dpy, EGLSurface surf,
    const EGLint *rects, EGLint n_rects)
{
    double t0 = now_ms();
    EGLBoolean r = real_swap_damage(dpy, surf, rects, n_rects);
    log_frame(t0, now_ms(), r, "SwpDmg");
    return r;
}

static EGLBoolean wrap_swap_interval(EGLDisplay dpy, EGLint interval)
{
    LOG("SwapInterval: requested=%d", interval);
    EGLBoolean r = real_swap_interval(dpy, interval);
    LOG("SwapInterval: result=%s", r ? "OK" : "FAIL");
    return r;
}

/* ── eglGetProcAddress wrapper ───────────────────────────────────── */

static void *wrap_getProcAddr(const char *name)
{
    void *ptr = real_getProcAddr(name);
    if (!ptr) return NULL;

    if (strcmp(name, "eglSwapBuffersWithDamageKHR") == 0 ||
        strcmp(name, "eglSwapBuffersWithDamageEXT") == 0) {
        real_swap_damage = (PFN_eglSwapBuffersWithDamage)ptr;
        LOG("Hooked %s", name);
        return (void *)wrap_swap_damage;
    }
    if (strcmp(name, "eglSwapBuffers") == 0) {
        real_swap = (PFN_eglSwapBuffers)ptr;
        LOG("Hooked eglSwapBuffers (via getProcAddr)");
        return (void *)wrap_swap;
    }
    if (strcmp(name, "eglSwapInterval") == 0) {
        real_swap_interval = (PFN_eglSwapInterval)ptr;
        LOG("Hooked eglSwapInterval (via getProcAddr)");
        return (void *)wrap_swap_interval;
    }

    return ptr;
}

/* ── dlsym interception ──────────────────────────────────────────── *
 * Bootstrapped via dlvsym (different function, no recursion).         *
 * Intercepts epoxy's dlsym(egl_handle, "eglGetProcAddress") to       *
 * inject our wrappers into the resolution chain.                      */

static void *(*real_dlsym)(void *, const char *) = NULL;

static void ensure_real_dlsym(void)
{
    if (!real_dlsym)
        real_dlsym = dlvsym(RTLD_NEXT, "dlsym", "GLIBC_2.34");
}

void *dlsym(void *handle, const char *symbol)
{
    ensure_real_dlsym();

    if (symbol) {
        if (strcmp(symbol, "eglGetProcAddress") == 0) {
            void *real = real_dlsym(handle, symbol);
            if (real) {
                real_getProcAddr = (PFN_eglGetProcAddress)real;
                LOG("Hooked eglGetProcAddress via dlsym");
                return (void *)wrap_getProcAddr;
            }
        }

        if (strcmp(symbol, "eglSwapBuffers") == 0) {
            void *real = real_dlsym(handle, symbol);
            if (real) {
                real_swap = (PFN_eglSwapBuffers)real;
                LOG("Hooked eglSwapBuffers via dlsym");
                return (void *)wrap_swap;
            }
        }

        if (strcmp(symbol, "eglSwapInterval") == 0) {
            void *real = real_dlsym(handle, symbol);
            if (real) {
                real_swap_interval = (PFN_eglSwapInterval)real;
                LOG("Hooked eglSwapInterval via dlsym");
                return (void *)wrap_swap_interval;
            }
        }
    }

    return real_dlsym(handle, symbol);
}

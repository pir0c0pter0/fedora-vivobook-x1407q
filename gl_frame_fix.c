/*
 * gl_frame_fix.c - LD_PRELOAD fix for GTK4 GL frame pacing on Wayland
 *
 * Problem: GTK4's GL renderer calls eglSwapInterval(0) every frame,
 * disabling vsync. During rapid text updates (terminal streaming),
 * this causes many partial presents that appear as flicker.
 *
 * Fix: Intercepts eglSwapInterval to force interval=1 (vsync), and
 * rate-limits eglSwapBuffers to prevent partial presents faster than
 * the display refresh rate.
 *
 * Chain: GTK4 → libepoxy → dlsym(dlopen("libEGL.so.1"), ...) → EGL
 * We intercept dlsym (bootstrapped via dlvsym) to hook into epoxy's
 * resolution chain.
 *
 * Build: gcc -shared -fPIC -o gl_frame_fix.so gl_frame_fix.c -ldl
 * Use:   GSK_RENDERER=gl LD_PRELOAD=/path/to/gl_frame_fix.so ptyxis
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <EGL/egl.h>
#include <string.h>
#include <stdio.h>
#include <time.h>
#include <stdint.h>

/* Minimum interval between presents (ms). ~60Hz = 16.6ms.
 * Use slightly less than one frame to avoid skipping valid frames. */
#define MIN_PRESENT_INTERVAL_MS 15.0

static inline double now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1000000.0;
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

/* ── frame pacing state ──────────────────────────────────────────── */

static double last_present_ms = 0;

/* ── swap interval fix: force vsync ──────────────────────────────── */

static EGLBoolean wrap_swap_interval(EGLDisplay dpy, EGLint interval)
{
    /* GTK4 calls eglSwapInterval(0) every frame — override to 1 */
    if (interval == 0)
        interval = 1;
    return real_swap_interval(dpy, interval);
}

/* ── swap rate limiter ───────────────────────────────────────────── */

static EGLBoolean wrap_swap(EGLDisplay dpy, EGLSurface surf)
{
    double now = now_ms();
    double elapsed = now - last_present_ms;

    /* Skip presents that come too fast (partial text updates) */
    if (last_present_ms > 0 && elapsed < MIN_PRESENT_INTERVAL_MS)
        return EGL_TRUE;

    last_present_ms = now;
    return real_swap(dpy, surf);
}

static EGLBoolean wrap_swap_damage(
    EGLDisplay dpy, EGLSurface surf,
    const EGLint *rects, EGLint n_rects)
{
    double now = now_ms();
    double elapsed = now - last_present_ms;

    if (last_present_ms > 0 && elapsed < MIN_PRESENT_INTERVAL_MS)
        return EGL_TRUE;

    last_present_ms = now;
    return real_swap_damage(dpy, surf, rects, n_rects);
}

/* ── eglGetProcAddress wrapper ───────────────────────────────────── */

static void *wrap_getProcAddr(const char *name)
{
    void *ptr = real_getProcAddr(name);
    if (!ptr) return NULL;

    if (strcmp(name, "eglSwapBuffersWithDamageKHR") == 0 ||
        strcmp(name, "eglSwapBuffersWithDamageEXT") == 0) {
        real_swap_damage = (PFN_eglSwapBuffersWithDamage)ptr;
        return (void *)wrap_swap_damage;
    }
    if (strcmp(name, "eglSwapBuffers") == 0) {
        real_swap = (PFN_eglSwapBuffers)ptr;
        return (void *)wrap_swap;
    }
    if (strcmp(name, "eglSwapInterval") == 0) {
        real_swap_interval = (PFN_eglSwapInterval)ptr;
        return (void *)wrap_swap_interval;
    }

    return ptr;
}

/* ── dlsym interception (bootstrapped via dlvsym) ────────────────── */

static void *(*real_dlsym)(void *, const char *) = NULL;

static void ensure_real_dlsym(void)
{
    if (!real_dlsym)
        real_dlsym = dlvsym(RTLD_NEXT, "dlsym", "GLIBC_2.34");
}

void *dlsym(void *handle, const char *symbol)
{
    ensure_real_dlsym();

    if (strcmp(symbol, "eglGetProcAddress") == 0) {
        void *real = real_dlsym(handle, symbol);
        if (real) {
            real_getProcAddr = (PFN_eglGetProcAddress)real;
            return (void *)wrap_getProcAddr;
        }
    }

    if (strcmp(symbol, "eglSwapBuffers") == 0) {
        void *real = real_dlsym(handle, symbol);
        if (real) {
            real_swap = (PFN_eglSwapBuffers)real;
            return (void *)wrap_swap;
        }
    }

    if (strcmp(symbol, "eglSwapInterval") == 0) {
        void *real = real_dlsym(handle, symbol);
        if (real) {
            real_swap_interval = (PFN_eglSwapInterval)real;
            return (void *)wrap_swap_interval;
        }
    }

    return real_dlsym(handle, symbol);
}

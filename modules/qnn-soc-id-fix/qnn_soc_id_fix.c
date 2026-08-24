/*
 * qnn_soc_id_fix.c - LD_PRELOAD shim que reporta outro SoC ID para o QNN
 *
 * Problema: libQnnHtp.so le /sys/devices/soc0/soc_id, encontra 635
 * (X1P42100), nao acha o ID na tabela interna e aborta em logCreate antes
 * de tocar o DSP. Nao existe env var de override na lib.
 *
 * Fix: intercepta as aberturas do caminho exato do soc_id e devolve um fd
 * para um memfd com "555\n" (X1E80100 / SC8380XP, que o QNN conhece e que
 * usa o mesmo Hexagon v73). Qualquer outro caminho passa direto.
 *
 * Build: make        Uso: LD_PRELOAD=/usr/local/lib64/qnn_soc_id_fix.so <cmd>
 *        (na pratica: tools/npu-run <cmd>, para nao virar estado global)
 *
 * Env:   QNN_SOC_ID_OVERRIDE  valor reportado   (default "555")
 *        QNN_SOC_ID_PATH      caminho alvo      (default /sys/devices/soc0/soc_id)
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define DEFAULT_SOC_ID "555"
#define DEFAULT_PATH   "/sys/devices/soc0/soc_id"

static int (*real_open)(const char *, int, ...);
static int (*real_open64)(const char *, int, ...);
static int (*real_openat)(int, const char *, int, ...);
static int (*real_openat64)(int, const char *, int, ...);
static FILE *(*real_fopen)(const char *, const char *);
static FILE *(*real_fopen64)(const char *, const char *);

static const char *target_path = DEFAULT_PATH;
static char fake_path[64];          /* /proc/self/fd/<n> do memfd */
static pthread_once_t once = PTHREAD_ONCE_INIT;

static void init(void)
{
    real_open     = dlsym(RTLD_NEXT, "open");
    real_open64   = dlsym(RTLD_NEXT, "open64");
    real_openat   = dlsym(RTLD_NEXT, "openat");
    real_openat64 = dlsym(RTLD_NEXT, "openat64");
    real_fopen    = dlsym(RTLD_NEXT, "fopen");
    real_fopen64  = dlsym(RTLD_NEXT, "fopen64");

    const char *p = getenv("QNN_SOC_ID_PATH");
    if (p && *p)
        target_path = p;

    const char *v = getenv("QNN_SOC_ID_OVERRIDE");
    if (!v || !*v)
        v = DEFAULT_SOC_ID;

    /* memfd: nada em disco, some junto com o processo. Reabrir por
     * /proc/self/fd/<n> da um file description novo (offset 0) a cada open. */
    int fd = memfd_create("qnn_soc_id", MFD_CLOEXEC);
    if (fd < 0)
        return;
    if (dprintf(fd, "%s\n", v) < 0) {
        close(fd);
        return;
    }
    snprintf(fake_path, sizeof(fake_path), "/proc/self/fd/%d", fd);
}

/* ponytail: strcmp literal — o QNN pede o caminho exato, sem symlink no meio, e
 * um realpath() aqui custaria um stat por open de todo processo. O mesmo
 * redirect serve para openat: target_path e absoluto, entao caminho relativo
 * nunca casa e o dirfd fica irrelevante. */
static const char *redirect(const char *path)
{
    /* volatile: glibc declara open()/fopen() com __nonnull((1)), entao o gcc
     * assume path != NULL e apaga um `if (!path)` comum — e um open(NULL) que
     * deveria dar EFAULT vira SIGSEGV dentro do strcmp. A leitura volatile nao
     * pode ser dobrada, entao o teste sobrevive ao -O2. */
    const char *volatile probe = path;

    pthread_once(&once, init);   /* antes do teste de NULL: real_* tem que existir */
    if (!probe)
        return NULL;
    if (fake_path[0] && strcmp(path, target_path) == 0)
        return fake_path;
    return path;
}

static int varmode(int flags, va_list ap)
{
    return (flags & (O_CREAT | O_TMPFILE)) ? va_arg(ap, int) : 0;
}

int open(const char *path, int flags, ...)
{
    va_list ap; va_start(ap, flags); int mode = varmode(flags, ap); va_end(ap);
    const char *p = redirect(path);
    return real_open(p, flags, mode);
}

int open64(const char *path, int flags, ...)
{
    va_list ap; va_start(ap, flags); int mode = varmode(flags, ap); va_end(ap);
    const char *p = redirect(path);
    return real_open64 ? real_open64(p, flags, mode) : real_open(p, flags, mode);
}

int openat(int dirfd, const char *path, int flags, ...)
{
    va_list ap; va_start(ap, flags); int mode = varmode(flags, ap); va_end(ap);
    return real_openat(dirfd, redirect(path), flags, mode);
}

int openat64(int dirfd, const char *path, int flags, ...)
{
    va_list ap; va_start(ap, flags); int mode = varmode(flags, ap); va_end(ap);
    const char *p = redirect(path);
    return real_openat64 ? real_openat64(dirfd, p, flags, mode)
                         : real_openat(dirfd, p, flags, mode);
}

FILE *fopen(const char *path, const char *mode)
{
    const char *p = redirect(path);
    return real_fopen(p, mode);
}

FILE *fopen64(const char *path, const char *mode)
{
    const char *p = redirect(path);
    return real_fopen64 ? real_fopen64(p, mode) : real_fopen(p, mode);
}

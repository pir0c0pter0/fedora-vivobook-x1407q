/*
 * sync_render.c - PTY proxy that eliminates terminal flicker
 *
 * Problem: Claude Code does erase+rewrite on every token, causing
 * visible flicker on ARM/Wayland where the redraw gap is noticeable.
 *
 * Fix: Creates a PTY proxy that coalesces rapid writes and wraps
 * them with Mode 2026 synchronized output markers. The terminal
 * buffers all changes and renders them atomically — zero flicker.
 *
 * How it works:
 * 1. Creates a pseudo-terminal (pty) pair
 * 2. Runs the target command on the slave pty
 * 3. Reads output from the master pty with a coalescing window
 * 4. Wraps coalesced output with \e[?2026h ... \e[?2026l
 * 5. Writes to the real terminal as a single atomic update
 *
 * Build: gcc -o sync_render sync_render.c -lutil
 * Use:   sync_render claude
 *        sync_render -- claude -p "hello"
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <poll.h>
#include <sys/wait.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <pty.h>

/* Normal coalescing window — catches erase+rewrite pairs from streaming output */
#define COALESCE_MS 20

/* Extended coalescing window for large redraws (full conversation reload).
 * Claude Code reloads take 200-500ms to generate. When the buffer has grown
 * past REDRAW_THRESHOLD, we use this longer window to keep waiting for more
 * data instead of flushing partial state. */
#define COALESCE_REDRAW_MS 200

/* Buffer size that indicates a large redraw is in progress (64KB).
 * Normal streaming output stays well below this. */
#define REDRAW_THRESHOLD (64 * 1024)

/* Max buffer size. Claude Code full conversation redraws can exceed 1MB
 * (long conversations with syntax highlighting). 16MB avoids mid-redraw
 * buffer flushes that would expose intermediate terminal states. */
#define BUF_MAX (16 * 1024 * 1024)

/* Mode 2026 synchronized output escape sequences */
static const char SYNC_START[] = "\033[?2026h";
static const char SYNC_END[]   = "\033[?2026l";

static volatile sig_atomic_t child_exited = 0;
static volatile sig_atomic_t got_winch = 0;
static int master_fd = -1;

static void sigchld_handler(int sig)
{
    (void)sig;
    child_exited = 1;
}

static void sigwinch_handler(int sig)
{
    (void)sig;
    got_winch = 1;
}

/* Forward window size changes to the child pty */
static void forward_winsize(int real_tty, int pty_master)
{
    struct winsize ws;
    if (ioctl(real_tty, TIOCGWINSZ, &ws) == 0)
        ioctl(pty_master, TIOCSWINSZ, &ws);
}

/* Write all bytes, handling partial writes */
static int write_all(int fd, const void *buf, size_t len)
{
    const char *p = buf;
    while (len > 0) {
        ssize_t n = write(fd, p, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        p += n;
        len -= n;
    }
    return 0;
}

/* Flush coalesced buffer with sync markers */
static void flush_synced(int out_fd, const char *buf, size_t len)
{
    if (len == 0) return;
    write_all(out_fd, SYNC_START, sizeof(SYNC_START) - 1);
    write_all(out_fd, buf, len);
    write_all(out_fd, SYNC_END, sizeof(SYNC_END) - 1);
}

int main(int argc, char *argv[])
{
    if (argc < 2) {
        fprintf(stderr, "Usage: sync_render <command> [args...]\n");
        return 1;
    }

    /* Skip "--" separator if present */
    int cmd_start = 1;
    if (argc > 2 && strcmp(argv[1], "--") == 0)
        cmd_start = 2;

    /* Save original terminal settings */
    int real_tty = STDIN_FILENO;
    struct termios orig_termios;
    int have_termios = (tcgetattr(real_tty, &orig_termios) == 0);

    /* Create pty pair */
    pid_t child = forkpty(&master_fd, NULL, NULL, NULL);
    if (child < 0) {
        perror("forkpty");
        return 1;
    }

    if (child == 0) {
        /* Child: run the command on the slave pty */
        execvp(argv[cmd_start], &argv[cmd_start]);
        perror("execvp");
        _exit(127);
    }

    /* Parent: proxy between real terminal and child pty */

    /* Forward initial window size */
    forward_winsize(real_tty, master_fd);

    /* Set up signal handlers */
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = sigchld_handler;
    sigaction(SIGCHLD, &sa, NULL);
    sa.sa_handler = sigwinch_handler;
    sigaction(SIGWINCH, &sa, NULL);

    /* Set real terminal to raw mode (pass input straight through) */
    if (have_termios) {
        struct termios raw = orig_termios;
        cfmakeraw(&raw);
        tcsetattr(real_tty, TCSANOW, &raw);
    }

    /* Coalescing buffer for child output */
    char *cbuf = malloc(BUF_MAX);
    if (!cbuf) {
        perror("malloc");
        goto cleanup;
    }
    size_t cbuf_len = 0;

    int out_fd = STDOUT_FILENO;
    struct pollfd fds[2];
    fds[0].fd = master_fd;      /* child output */
    fds[0].events = POLLIN;
    fds[1].fd = real_tty;       /* user input */
    fds[1].events = POLLIN;

    while (!child_exited || cbuf_len > 0) {
        /* Handle window resize */
        if (got_winch) {
            got_winch = 0;
            forward_winsize(real_tty, master_fd);
        }

        int timeout = cbuf_len == 0 ? -1 :
                      cbuf_len > REDRAW_THRESHOLD ? COALESCE_REDRAW_MS : COALESCE_MS;
        int ret = poll(fds, 2, timeout);

        if (ret < 0) {
            if (errno == EINTR) continue;
            break;
        }

        if (ret == 0) {
            /* Timeout: coalescing window expired, flush */
            flush_synced(out_fd, cbuf, cbuf_len);
            cbuf_len = 0;
            continue;
        }

        /* User input → forward to child */
        if (fds[1].revents & POLLIN) {
            char ibuf[4096];
            ssize_t n = read(real_tty, ibuf, sizeof(ibuf));
            if (n > 0)
                write_all(master_fd, ibuf, n);
            else if (n == 0)
                break;
        }

        /* Child output → coalesce and sync */
        if (fds[0].revents & POLLIN) {
            size_t space = BUF_MAX - cbuf_len;
            if (space == 0) {
                /* Buffer full, flush what we have */
                flush_synced(out_fd, cbuf, cbuf_len);
                cbuf_len = 0;
                space = BUF_MAX;
            }
            ssize_t n = read(master_fd, cbuf + cbuf_len, space);
            if (n > 0) {
                cbuf_len += n;
            } else if (n <= 0) {
                /* Child closed pty */
                flush_synced(out_fd, cbuf, cbuf_len);
                cbuf_len = 0;
                break;
            }
        }

        /* Child pty hung up */
        if (fds[0].revents & (POLLHUP | POLLERR)) {
            flush_synced(out_fd, cbuf, cbuf_len);
            cbuf_len = 0;
            break;
        }
    }

    free(cbuf);

cleanup:
    /* Restore terminal */
    if (have_termios)
        tcsetattr(real_tty, TCSANOW, &orig_termios);

    /* Get child exit status */
    int status = 0;
    waitpid(child, &status, 0);

    if (WIFEXITED(status))
        return WEXITSTATUS(status);
    return 1;
}

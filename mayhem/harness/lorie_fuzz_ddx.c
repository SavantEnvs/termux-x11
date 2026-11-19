/*
 * mayhem: a host (Linux) DDX that runs termux-x11's lorie clipboard code (lorie/clipboard.c,
 * compiled unmodified) inside the Xvfb DDX of the xserver termux-x11 pins.
 *
 * The real lorie DDX (lorie/InitOutput.c) renders through Android EGL/AHardwareBuffer, which does
 * not exist on Linux, so the screen comes from hw/vfb (its InitOutput/ddxProcessArgument are
 * renamed with -D at compile time and wrapped here). After screen init we do what lorie's
 * InitOutput does for the clipboard: set pScreenPtr, lorieInitClipboard(), and enable clipboard
 * sync (as the Android activity does when the user enables it).
 *
 * Input: `-fuzzinput <file>`. Its bytes are the stream an X11 client writes to the server
 * (connection setup + requests). Once the server is dispatching, a work proc connects one client
 * over a socketpair (AddClientOnOpenFD, the server's own entry for pre-opened client fds); a
 * thread writes the file into the client end, half-closes it, and drains the replies. With
 * `-terminate` the server exits once that client is gone, so one process = one input.
 *
 * The Android-side callbacks lorie calls (lorieSendClipboardData / lorieRequestClipboard) are
 * replaced by recorders that print what lorie would have sent to the activity, which is what
 * mayhem/test.sh asserts on.
 */
#include <dix-config.h>

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#include "scrnintstr.h"
#include "dixstruct.h"
#include "os.h"
#include "opaque.h"

extern void vfbInitOutput(ScreenInfo *screen_info, int argc, char **argv);
extern int vfbddxProcessArgument(int argc, char *argv[], int i);
extern void lorieInitClipboard(void);
extern void lorieEnableClipboardSync(Bool enable);

ScreenPtr pScreenPtr; /* lorie/clipboard.c: extern ScreenPtr pScreenPtr (defined in lorie/InitOutput.c) */

static const char *fuzzInput;
static Bool fuzzClientStarted;

/* ---- Android-side stand-ins ---------------------------------------------------------------- */

int __android_log_print(int prio, const char *tag, const char *fmt, ...) {
    (void) prio; (void) tag; (void) fmt;
    return 0;
}

void lorieSendClipboardData(const char *data) {
    /* Record exactly what lorie hands to the Android activity: length + hex bytes. */
    size_t n = strlen(data);
    fprintf(stdout, "LORIE_CLIPBOARD_SEND %zu ", n);
    for (size_t i = 0; i < n; i++)
        fprintf(stdout, "%02x", (unsigned char) data[i]);
    fputc('\n', stdout);
    fflush(stdout);
}

void lorieRequestClipboard(void) {
    fputs("LORIE_CLIPBOARD_REQUEST\n", stdout);
    fflush(stdout);
}

/* ---- client feeder --------------------------------------------------------------------------- */

struct feed { int fd; char *buf; size_t len; };

static void *feederThread(void *arg) {
    struct feed *f = arg;
    size_t off = 0;
    char sink[4096];
    while (off < f->len) {
        ssize_t w = write(f->fd, f->buf + off, f->len - off);
        if (w < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        off += (size_t) w;
    }
    shutdown(f->fd, SHUT_WR);
    for (;;) {
        ssize_t r = read(f->fd, sink, sizeof(sink));
        if (r == 0 || (r < 0 && errno != EINTR))
            break;
    }
    close(f->fd);
    free(f->buf);
    free(f);
    return NULL;
}

static Bool startFuzzClient(ClientPtr client, void *closure) {
    (void) client; (void) closure;
    int sv[2];
    struct feed *f = calloc(1, sizeof(*f));
    FILE *fp = fopen(fuzzInput, "rb");
    if (!f || !fp)
        FatalError("mayhem: cannot open -fuzzinput %s\n", fuzzInput);
    fseek(fp, 0, SEEK_END);
    long len = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    f->buf = malloc(len > 0 ? (size_t) len : 1);
    f->len = len > 0 ? fread(f->buf, 1, (size_t) len, fp) : 0;
    fclose(fp);

    if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sv) != 0)
        FatalError("mayhem: socketpair failed\n");
    f->fd = sv[1];
    if (!AddClientOnOpenFD(sv[0]))
        FatalError("mayhem: AddClientOnOpenFD failed\n");

    pthread_t t;
    if (pthread_create(&t, NULL, feederThread, f) != 0)
        FatalError("mayhem: pthread_create failed\n");
    pthread_detach(t);
    return TRUE;
}

/* ---- DDX wrappers ---------------------------------------------------------------------------- */

int ddxProcessArgument(int argc, char *argv[], int i) {
    if (strcmp(argv[i], "-fuzzinput") == 0 && i + 1 < argc) {
        fuzzInput = argv[i + 1];
        return 2;
    }
    return vfbddxProcessArgument(argc, argv, i);
}

/*
 * xkb/ddxLoad.c compiles the keymap (xkbcomp) into <xkb_output_dir>/server-<display>.xkm on every
 * server start, loads it and unlinks it. Every fuzz process is started as `:99`, so parallel
 * processes would write, read and delete the same file. Give each process its own name: `display`
 * only names that file from here on (sockets and the vfb XWD header are already done, -nolock,
 * no XDMCP, no -logfile). The file stays in the server's own output dir and is unlinked by it.
 */
static void uniqueKeymapName(void) {
    static char name[64];
    snprintf(name, sizeof(name), "%s-%ld", display ? display : "0", (long) getpid());
    display = name;
}

void InitOutput(ScreenInfo *screen_info, int argc, char **argv) {
    vfbInitOutput(screen_info, argc, argv);
    uniqueKeymapName(); /* after vfb wrote `display` into its XWD header; before InitInput's xkbcomp */
    pScreenPtr = screen_info->screens[0];
    lorieInitClipboard();
    lorieEnableClipboardSync(TRUE);
    if (fuzzInput && !fuzzClientStarted) {
        fuzzClientStarted = TRUE;
        QueueWorkProc(startFuzzClient, NULL, NULL);
    }
}

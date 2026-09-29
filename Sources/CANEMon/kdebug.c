// Minimal kdebug client over the KERN_KDEBUG sysctls (the interface ktrace,
// fs_usage and friends are built on). Requires root.

#include "canemon.h"

#include <errno.h>
#include <mach/mach_time.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>

// Private kdebug definitions (xnu bsd/sys/kdebug_private.h).
typedef struct {
    int nkdbufs;
    int nolog;
    unsigned int flags;
    int nkdthreads;
    int bufid;
} kbufinfo_t;

#define KDBG_TYPEFILTER_BYTES (256 * 256 / 8)
#define KDBG_NOWRAP 0x02

static int started;

static int kd_ctl(int op, int value, void *buf, size_t *len) {
    int mib[4] = {CTL_KERN, KERN_KDEBUG, op, value};
    return sysctl(mib, 4, buf, len, NULL, 0);
}

static int kd_ctl3(int op, void *buf, size_t *len) {
    int mib[3] = {CTL_KERN, KERN_KDEBUG, op};
    return sysctl(mib, 3, buf, len, NULL, 0);
}

int anemon_kd_start(const uint16_t *csc, int ncsc, int nbufs, int *busy_pid) {
    if (busy_pid) *busy_pid = -1;
    if (geteuid() != 0) return ANEMON_KD_NOT_ROOT;

    kbufinfo_t info;
    size_t len = sizeof(info);
    memset(&info, 0, sizeof(info));
    if (kd_ctl3(KERN_KDGETBUF, &info, &len) == 0 && busy_pid) *busy_pid = info.bufid;

    // Tear down any stale configuration. EBUSY means another foreground
    // tracer (ktrace, Instruments, fs_usage) currently owns kdebug.
    if (kd_ctl3(KERN_KDREMOVE, NULL, &(size_t){0}) != 0 && errno == EBUSY)
        return ANEMON_KD_BUSY;

    size_t zero = 0;
    if (kd_ctl(KERN_KDSETBUF, nbufs, NULL, &zero) != 0) goto fail;
    zero = 0;
    if (kd_ctl3(KERN_KDSETUP, NULL, &zero) != 0) goto fail;
    // Ring-buffer mode: when readers fall behind, overwrite the oldest records
    // instead of stopping (the default no-wrap mode halts tracing when full).
    zero = 0;
    kd_ctl(KERN_KDDFLAGS, KDBG_NOWRAP, NULL, &zero);

    uint8_t *filter = calloc(1, KDBG_TYPEFILTER_BYTES);
    if (!filter) goto fail;
    for (int i = 0; i < ncsc; i++) filter[csc[i] / 8] |= (uint8_t)(1u << (csc[i] % 8));
    size_t flen = KDBG_TYPEFILTER_BYTES;
    int rc = kd_ctl3(KERN_KDSET_TYPEFILTER, filter, &flen);
    free(filter);
    if (rc != 0) goto fail;

    zero = 0;
    if (kd_ctl(KERN_KDENABLE, 1, NULL, &zero) != 0) goto fail;
    started = 1;
    return ANEMON_KD_OK;

fail:;
    int busy = errno == EBUSY;
    anemon_kd_stop();
    return busy ? ANEMON_KD_BUSY : ANEMON_KD_FAILED;
}

int anemon_kd_read(anemon_kd_buf *out, int cap) {
    // For KERN_KDREADTR the length is a record count, not a byte count.
    size_t n = (size_t)cap;
    if (kd_ctl3(KERN_KDREADTR, out, &n) != 0) return -1;
    return (int)n;
}

int anemon_kd_status(int *nolog, unsigned *flags, int *nbufs) {
    kbufinfo_t info;
    size_t len = sizeof(info);
    memset(&info, 0, sizeof(info));
    if (kd_ctl3(KERN_KDGETBUF, &info, &len) != 0) return -1;
    if (nolog) *nolog = info.nolog;
    if (flags) *flags = info.flags;
    if (nbufs) *nbufs = info.nkdbufs;
    return 0;
}

int anemon_kd_reenable(void) {
    size_t zero = 0;
    return kd_ctl(KERN_KDENABLE, 1, NULL, &zero);
}

void anemon_kd_stop(void) {
    size_t zero = 0;
    kd_ctl(KERN_KDENABLE, 0, NULL, &zero);
    zero = 0;
    kd_ctl3(KERN_KDREMOVE, NULL, &zero);
    started = 0;
}

static mach_timebase_info_data_t tb;

double anemon_mach_to_ns(uint64_t t) {
    if (tb.denom == 0) mach_timebase_info(&tb);
    return (double)t * tb.numer / tb.denom;
}

uint64_t anemon_mach_now(void) { return mach_absolute_time(); }

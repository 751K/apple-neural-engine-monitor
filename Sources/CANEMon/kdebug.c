// Minimal kdebug client over the KERN_KDEBUG sysctls (the interface ktrace,
// fs_usage and friends are built on). Requires root.

#include "canemon.h"

#include <errno.h>
#include <libproc.h>

#ifndef PROC_PIDLISTTHREADIDS
#define PROC_PIDLISTTHREADIDS 28   // private in xnu bsd/sys/proc_info.h
#endif
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

#define KDBG_NOWRAP 0x02
#define KDBG_VALCHECK 0x00200000U
#define KDBG_SUBCLSTYPE 0x20000

typedef struct {
    unsigned int type;
    unsigned int value1, value2, value3, value4;
} kd_regtype;

static int started;

static int kd_ctl(int op, int value, void *buf, size_t *len) {
    int mib[4] = {CTL_KERN, KERN_KDEBUG, op, value};
    return sysctl(mib, 4, buf, len, NULL, 0);
}

static int kd_ctl3(int op, void *buf, size_t *len) {
    int mib[3] = {CTL_KERN, KERN_KDEBUG, op};
    return sysctl(mib, 3, buf, len, NULL, 0);
}

int anemon_kd_start(const uint32_t *ids, int nids, int nbufs, int *busy_pid) {
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

    // Record only the given event ids. A class/subclass typefilter would also
    // pass the ANE driver's other events (~90k/s on M6), and every read then
    // advances the kernel's oldest-valid time past firmware events that are
    // still on their way from the coprocessor, which the kernel drops as
    // "past events" (xnu bsd/kern/kdebug.c). With exact ids the M6 lost ~0.2%
    // of its firmware task events instead of ~10%.
    if (nids < 1 || nids > 4) { errno = EINVAL; goto fail; }
    kd_regtype r = {KDBG_VALCHECK, 0, 0, 0, 0};
    unsigned int *v[4] = {&r.value1, &r.value2, &r.value3, &r.value4};
    for (int i = 0; i < 4; i++) *v[i] = ids[i < nids ? i : 0];
    // Research aid: ANEMON_KD_ALL=1 records the first id's whole
    // class/subclass instead (and accepts the losses above).
    const char *all = getenv("ANEMON_KD_ALL");
    if (all && *all == '1') r = (kd_regtype){KDBG_SUBCLSTYPE, ids[0] >> 24, (ids[0] >> 16) & 0xff, 0, 0};
    size_t rlen = sizeof(r);
    if (kd_ctl3(KERN_KDSETREG, &r, &rlen) != 0) goto fail;

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

double anemon_slept_ns(void) {
    uint64_t a = mach_absolute_time(), c = mach_continuous_time();
    return c > a ? anemon_mach_to_ns(c - a) : 0;
}

int anemon_thread_owner(uint64_t tid, char *name, int namelen) {
    int n = proc_listallpids(NULL, 0);
    if (n <= 0) return -1;
    pid_t *pids = calloc((size_t)n + 64, sizeof(pid_t));
    if (!pids) return -1;
    n = proc_listallpids(pids, (int)((n + 64) * sizeof(pid_t)));
    uint64_t *tids = NULL;
    int cap = 0, found = -1;
    for (int i = 0; i < n && found < 0; i++) {
        struct proc_taskinfo ti;
        if (proc_pidinfo(pids[i], PROC_PIDTASKINFO, 0, &ti, sizeof(ti)) != sizeof(ti)) continue;
        int want = ti.pti_threadnum + 16;
        if (want > cap) {
            uint64_t *t = realloc(tids, (size_t)want * sizeof(uint64_t));
            if (!t) break;
            tids = t;
            cap = want;
        }
        int bytes = proc_pidinfo(pids[i], PROC_PIDLISTTHREADIDS, 0, tids, cap * (int)sizeof(uint64_t));
        for (int j = 0; j < bytes / (int)sizeof(uint64_t); j++) {
            if (tids[j] == tid) { found = pids[i]; break; }
        }
    }
    free(tids);
    free(pids);
    if (found >= 0 && name && namelen > 0) {
        name[0] = 0;
        proc_name(found, name, (uint32_t)namelen);
    }
    return found;
}

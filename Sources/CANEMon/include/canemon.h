#ifndef CANEMON_H
#define CANEMON_H

#include <stdint.h>
#include <stddef.h>

// ---- kdebug -------------------------------------------------------------

// One kernel trace record (arm64 layout of the private kd_buf).
typedef struct {
    uint64_t timestamp;   // mach_absolute_time units
    uint64_t arg1;
    uint64_t arg2;
    uint64_t arg3;
    uint64_t arg4;
    uint64_t arg5;        // thread id
    uint32_t debugid;
    uint32_t cpuid;
    uint64_t unused;
} anemon_kd_buf;

// Status codes returned by anemon_kd_start.
enum {
    ANEMON_KD_OK = 0,
    ANEMON_KD_NOT_ROOT = 1,
    ANEMON_KD_BUSY = 2,     // another process owns the trace facility
    ANEMON_KD_FAILED = 3,
};

// Starts kernel tracing restricted to the given class/subclass pairs
// (each encoded as (class << 8) | subclass). Returns an ANEMON_KD_* code.
// *busy_pid is set to the owner when ANEMON_KD_BUSY is returned.
int anemon_kd_start(const uint16_t *csc, int ncsc, int nbufs, int *busy_pid);

// Drains up to cap records into out. Returns the count, or -1 on error.
int anemon_kd_read(anemon_kd_buf *out, int cap);

// Reports whether the kernel stopped logging (nolog != 0), the trace flags
// and the kernel buffer size in records. Returns 0 on success.
int anemon_kd_status(int *nolog, unsigned *flags, int *nbufs);

// Turns logging back on after the kernel stopped it.
int anemon_kd_reenable(void);

// Disables tracing and releases the kernel buffers. Safe to call repeatedly.
void anemon_kd_stop(void);

// Converts mach absolute time to nanoseconds.
double anemon_mach_to_ns(uint64_t t);
uint64_t anemon_mach_now(void);

// ---- IOReport -----------------------------------------------------------

// Opaque sampler over a fixed set of IOReport channels.
typedef struct anemon_ior anemon_ior;

// Simple integer channels are matched by group, subgroup (NULL = any) and
// channel name. Returns NULL if libIOReport cannot be loaded.
anemon_ior *anemon_ior_open(void);

// Takes a sample and writes deltas since the previous call:
// DRAM bytes read/written by the ANE (AMC DCS counters) and ANE interrupt count.
// Returns 0 on success; the first call only primes the baseline and returns 1.
int anemon_ior_sample(anemon_ior *r, uint64_t *rd_bytes, uint64_t *wr_bytes,
                      uint64_t *interrupts);

void anemon_ior_close(anemon_ior *r);

#endif

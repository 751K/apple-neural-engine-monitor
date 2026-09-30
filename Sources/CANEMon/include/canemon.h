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
// Continuous time minus absolute time, in ns: how long the Mac has slept
// since boot.
double anemon_slept_ns(void);

// ---- IOReport -----------------------------------------------------------

// Opaque sampler over a fixed set of IOReport channels.
typedef struct anemon_ior anemon_ior;

// Returns NULL if libIOReport cannot be loaded or no channel group of
// interest can be subscribed.
anemon_ior *anemon_ior_open(void);

// Which counters a sample found. Channel names differ between chips, so a
// missing channel must not be reported as zero traffic.
enum {
    ANEMON_IOR_DRAM = 1,        // AMC "ANE DCS RD/WR" byte counters (M4)
    ANEMON_IOR_INTERRUPTS = 2,  // "Interrupt Statistics" ane channels
    ANEMON_IOR_DRAM_HIST = 4,   // PMP "DCS BW" per-link ANE bandwidth histograms (M6)
    ANEMON_IOR_PCLUSTER = 8,    // PMP "Energy" P-cluster power histograms
};

// Deltas since the previous sample.
typedef struct {
    int found;                  // mask of ANEMON_IOR_*
    uint64_t dram_rd_bytes;     // AMC counters
    uint64_t dram_wr_bytes;
    uint64_t interrupts;
    // Link histograms: sum over links and samples of the bin midpoint (GB/s).
    // A sample is taken only while a link is active, at a fixed rate, so
    // hist_rd / samples_per_s_per_link / seconds is the mean read GB/s.
    double hist_rd, hist_wr;
    uint64_t hist_rd_samples;   // read samples, all links
    uint64_t hist_rd_top;       // read samples in the highest bin (clipped)
    int hist_links;             // read links seen
    double pcluster_w;          // mean P-cluster power incl. SRAM, all clusters
} anemon_ior_values;

// Takes a sample and writes deltas since the previous call into *v.
// Returns 0 on success; the first call only primes the baseline and returns 1.
int anemon_ior_sample(anemon_ior *r, anemon_ior_values *v);

void anemon_ior_close(anemon_ior *r);

// ---- SMC ----------------------------------------------------------------

// Opens the AppleSMC user client (no root needed). Returns 0 on success.
int anemon_smc_open(void);

// Reads a 4-byte float key such as "PP0b". Returns 0 on success.
int anemon_smc_read_float(const char *key, float *out);

void anemon_smc_close(void);

#endif

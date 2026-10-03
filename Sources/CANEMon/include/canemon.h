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

// Starts kernel tracing restricted to 1-4 event ids (the function qualifier
// bits are ignored, so 0x061b0124 covers both 0x061b0125 and 0x061b0126).
// Returns an ANEMON_KD_* code. *busy_pid is set to the owner when
// ANEMON_KD_BUSY is returned.
int anemon_kd_start(const uint32_t *ids, int nids, int nbufs, int *busy_pid);

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

// Finds the process that owns a thread (the 64-bit thread id in kd_buf
// arg5). Returns its pid and copies its name into name, or returns -1.
// Scans every process, so callers should cache the result.
int anemon_thread_owner(uint64_t tid, char *name, int namelen);

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
    ANEMON_IOR_DCS_LEVELS = 16, // SoC Stats "DCS_F<n>" DRAM frequency level residency
    ANEMON_IOR_THROTTLE = 32,   // SoC Stats "ANE_THROTTLE_*_TRIG" residency
    ANEMON_IOR_IOP = 64,        // "ANE" / "ANE1" IOP State residency
};

// Throttle triggers in anemon_ior_values.throttle_ticks, in this order:
// SW, HW, ADCLK, DITHER, PPT, EXT0, EXT1, EXT2, EXT3.
#define ANEMON_THROTTLE_KINDS 9

// IOP (ANE firmware processor) states, summarised.
enum { ANEMON_IOP_OFF = 0, ANEMON_IOP_RUNNING = 1, ANEMON_IOP_OTHER = 2, ANEMON_IOP_KINDS = 3 };
#define ANEMON_MAX_ENGINES 4
#define ANEMON_MAX_DCS_LEVELS 16

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
    // DRAM frequency levels: 24 MHz ticks spent at each "DCS_F<n>" level.
    uint64_t dcs_level_ticks[ANEMON_MAX_DCS_LEVELS];
    // ANE throttling: ticks each trigger was active, and the interval length
    // in ticks (active + inactive of one trigger).
    uint64_t throttle_ticks[ANEMON_THROTTLE_KINDS];
    uint64_t throttle_span_ticks;
    // IOP state per engine ("ANE" = 0, "ANE1" = 1, ...): ticks off, running, other.
    uint64_t iop_ticks[ANEMON_MAX_ENGINES][ANEMON_IOP_KINDS];
    int iop_engines;            // highest engine index seen + 1
} anemon_ior_values;

// Takes a sample and writes deltas since the previous call into *v.
// Returns 0 on success; the first call only primes the baseline and returns 1.
int anemon_ior_sample(anemon_ior *r, anemon_ior_values *v);

void anemon_ior_close(anemon_ior *r);

// `anemon diagnose`: every channel the kernel offers, for a chip whose
// channel names are not known yet.
//
// Called once per channel. values holds nvalues entries: one integer for a
// simple counter (labels NULL), or the residency of each state, named by
// labels, for a state or histogram channel. Other formats pass nvalues 0.
typedef void (*anemon_ior_visit_fn)(void *ctx, const char *group, const char *subgroup, const char *name,
                                    int format, int nvalues, const char *const *labels, const int64_t *values);

// Lists every channel of every group, without values or subscribing.
int anemon_ior_list_all(anemon_ior_visit_fn fn, void *ctx);

// Subscribes every group / subgroup that can be subscribed on its own.
// *unsubscribed is set to the number of group / subgroup pairs refused.
anemon_ior *anemon_ior_open_all(int *unsubscribed);

// Takes a sample and calls fn with each channel's delta since the previous
// call. The first call only primes the baseline and returns 1.
int anemon_ior_visit(anemon_ior *r, anemon_ior_visit_fn fn, void *ctx);

// ---- SMC ----------------------------------------------------------------

// Opens the AppleSMC user client (no root needed). Returns 0 on success.
int anemon_smc_open(void);

// Reads a 4-byte float key such as "PP0b". Returns 0 on success.
int anemon_smc_read_float(const char *key, float *out);

// Number of SMC keys, and the key at an index (4 characters plus NUL).
int anemon_smc_key_count(void);
int anemon_smc_key_at(uint32_t index, char out[5]);

void anemon_smc_close(void);

#endif

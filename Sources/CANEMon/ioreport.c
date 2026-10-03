// ANE memory traffic, interrupt counters and CPU cluster power from the
// private IOReport library, loaded with dlopen so the binary does not need
// its stub. Works without root.
//
// Sources, each subscribed only if the kernel accepts it on its own (a group
// that cannot be subscribed would otherwise be dropped silently from a merged
// subscription):
//   AMC Stats / Perf Counters   exact ANE DRAM bytes ("ANE DCS RD/WR"; M4)
//   PMP / DCS BW                per-link ANE bandwidth histograms ("ANE0 L0 RD"; M6)
//   PMP / Energy                CPU cluster power histograms ("PACC0", "PACC0 SRAM")
//   Interrupt Statistics        ANE interrupt counts
//   SoC Stats / Events          DRAM frequency levels ("DCS_F<n>") and ANE
//                               throttle triggers ("ANE_THROTTLE_*_TRIG")
//   ANE, ANE1 / IOP State       state of each engine's firmware processor

#include "canemon.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

typedef CFMutableDictionaryRef (*copy_group_fn)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
typedef void (*merge_fn)(CFMutableDictionaryRef, CFMutableDictionaryRef, CFTypeRef);
typedef void *(*create_sub_fn)(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
typedef CFDictionaryRef (*create_samples_fn)(void *, CFMutableDictionaryRef, CFTypeRef);
typedef CFDictionaryRef (*samples_delta_fn)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
typedef CFStringRef (*get_str_fn)(CFDictionaryRef);
typedef int64_t (*get_int_fn)(CFDictionaryRef, int32_t);
typedef int32_t (*get_i32_fn)(CFDictionaryRef);
typedef CFStringRef (*state_name_fn)(CFDictionaryRef, int32_t);
typedef int64_t (*state_res_fn)(CFDictionaryRef, int32_t);

struct anemon_ior {
    void *lib;
    copy_group_fn copy_group;
    merge_fn merge;
    create_sub_fn create_sub;
    create_samples_fn create_samples;
    samples_delta_fn delta;
    get_str_fn group, subgroup, name;
    get_int_fn int_value;
    get_i32_fn format, state_count;
    state_name_fn state_name;
    state_res_fn residency;
    void *sub;
    CFMutableDictionaryRef subbed;
    CFDictionaryRef prev;
    int dump_channels;
};

// "ANE DCS ..." (M4) or "ANE<n> DCS ..." (one per engine).
static int is_ane_dcs(const char *s) {
    if (strncasecmp(s, "ANE", 3) != 0) return 0;
    s += 3;
    while (*s >= '0' && *s <= '9') s++;
    return strncasecmp(s, " DCS ", 5) == 0;
}

// PMP DCS BW link histogram: "ANE<n> L<n> RD" (M6, two links per engine),
// "ANE<n> RD" (M4, one link) or the same with WR (not "RD+WR").
// Returns 1 for read, 2 for write, 0 otherwise.
static int ane_link_dir(const char *s) {
    if (strncmp(s, "ANE", 3) != 0) return 0;
    s += 3;
    if (*s < '0' || *s > '9') return 0;
    while (*s >= '0' && *s <= '9') s++;
    if (strncmp(s, " L", 2) == 0) {
        s += 2;
        if (*s < '0' || *s > '9') return 0;
        while (*s >= '0' && *s <= '9') s++;
    }
    if (strcmp(s, " RD") == 0) return 1;
    if (strcmp(s, " WR") == 0) return 2;
    return 0;
}

// P-cluster power histograms: "PACC<n>" and "PACC<n> SRAM".
static int is_pcluster(const char *s) {
    if (strncmp(s, "PACC", 4) != 0) return 0;
    s += 4;
    if (*s < '0' || *s > '9') return 0;
    while (*s >= '0' && *s <= '9') s++;
    return *s == 0 || strcmp(s, " SRAM") == 0;
}

static const char *const anemon_throttle_names[ANEMON_THROTTLE_KINDS] = {
    "SW", "HW", "ADCLK", "DITHER", "PPT", "EXT0", "EXT1", "EXT2", "EXT3",
};

// "ANE_THROTTLE_<kind>_TRIG" (EXT triggers are "ANE_THROTTLE_EXT_TRIG<n>").
// Returns the index into anemon_throttle_names, or -1.
static int throttle_kind(const char *s) {
    if (strncmp(s, "ANE_THROTTLE_", 13) != 0) return -1;
    s += 13;
    if (strncmp(s, "EXT_TRIG", 8) == 0 && s[8] >= '0' && s[8] <= '3' && s[9] == 0) return 5 + (s[8] - '0');
    for (int i = 0; i < 5; i++) {
        size_t n = strlen(anemon_throttle_names[i]);
        if (strncmp(s, anemon_throttle_names[i], n) == 0 && strcmp(s + n, "_TRIG") == 0) return i;
    }
    return -1;
}

// "DCS_F<n>": returns n, or -1.
static int dcs_level(const char *s) {
    if (strncmp(s, "DCS_F", 5) != 0 || s[5] < '0' || s[5] > '9') return -1;
    char *end;
    long n = strtol(s + 5, &end, 10);
    return *end == 0 && n < ANEMON_MAX_DCS_LEVELS ? (int)n : -1;
}

// IOP State groups: "ANE" is engine 0, "ANE<n>" engine n. Returns -1 otherwise.
static int iop_engine(const char *grp) {
    if (strcmp(grp, "ANE") == 0) return 0;
    if (strncmp(grp, "ANE", 3) != 0 || grp[3] < '1' || grp[3] > '9' || grp[4] != 0) return -1;
    int n = grp[3] - '0';
    return n < ANEMON_MAX_ENGINES ? n : -1;
}

// Interrupt subgroups: "ane 2" (M4) or "ane1 2" (second engine).
static int is_ane_irq(const char *s) {
    if (strncasecmp(s, "ane", 3) != 0) return 0;
    s += 3;
    while (*s >= '0' && *s <= '9') s++;
    return *s == ' ';
}

static void cfstr(CFStringRef s, char *buf, size_t n) {
    buf[0] = 0;
    if (s) CFStringGetCString(s, buf, (CFIndex)n, kCFStringEncodingUTF8);
}

typedef int (*keep_fn)(const char *name);
static int keep_ane_dcs(const char *n) { return is_ane_dcs(n); }
static int keep_ane_link(const char *n) { return ane_link_dir(n) != 0; }
static int keep_pcluster(const char *n) { return is_pcluster(n); }
static int keep_soc_events(const char *n) { return dcs_level(n) >= 0 || throttle_kind(n) >= 0; }

// Copies a group's channels, keeping those accepted by keep (NULL = all),
// and returns them only if they can be subscribed on their own.
static CFMutableDictionaryRef usable(anemon_ior *r, CFStringRef group, CFStringRef subgroup, keep_fn keep) {
    CFMutableDictionaryRef d = r->copy_group(group, subgroup, 0, 0, 0);
    if (!d) return NULL;
    if (keep) {
        CFArrayRef a = CFDictionaryGetValue(d, CFSTR("IOReportChannels"));
        CFMutableArrayRef f = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
        char name[128];
        for (CFIndex i = 0; a && i < CFArrayGetCount(a); i++) {
            CFDictionaryRef ch = CFArrayGetValueAtIndex(a, i);
            cfstr(r->name(ch), name, sizeof name);
            if (keep(name)) CFArrayAppendValue(f, ch);
        }
        CFDictionarySetValue(d, CFSTR("IOReportChannels"), f);
        CFRelease(f);
    }
    CFArrayRef a = CFDictionaryGetValue(d, CFSTR("IOReportChannels"));
    CFMutableDictionaryRef subbed = NULL;
    void *sub = a && CFArrayGetCount(a) > 0 ? r->create_sub(NULL, d, &subbed, 0, NULL) : NULL;
    if (subbed) CFRelease(subbed);
    if (!sub) {
        CFRelease(d);
        return NULL;
    }
    return d;
}

// Loads libIOReport and resolves its functions, without subscribing.
static anemon_ior *ior_load(void) {
    void *lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY);
    if (!lib) return NULL;
    anemon_ior *r = calloc(1, sizeof(*r));
    r->lib = lib;
    r->copy_group = (copy_group_fn)dlsym(lib, "IOReportCopyChannelsInGroup");
    r->merge = (merge_fn)dlsym(lib, "IOReportMergeChannels");
    r->create_sub = (create_sub_fn)dlsym(lib, "IOReportCreateSubscription");
    r->create_samples = (create_samples_fn)dlsym(lib, "IOReportCreateSamples");
    r->delta = (samples_delta_fn)dlsym(lib, "IOReportCreateSamplesDelta");
    r->group = (get_str_fn)dlsym(lib, "IOReportChannelGetGroup");
    r->subgroup = (get_str_fn)dlsym(lib, "IOReportChannelGetSubGroup");
    r->name = (get_str_fn)dlsym(lib, "IOReportChannelGetChannelName");
    r->int_value = (get_int_fn)dlsym(lib, "IOReportSimpleGetIntegerValue");
    r->format = (get_i32_fn)dlsym(lib, "IOReportChannelGetFormat");
    r->state_count = (get_i32_fn)dlsym(lib, "IOReportStateGetCount");
    r->state_name = (state_name_fn)dlsym(lib, "IOReportStateGetNameForIndex");
    r->residency = (state_res_fn)dlsym(lib, "IOReportStateGetResidency");
    if (!r->copy_group || !r->merge || !r->create_sub || !r->create_samples || !r->delta || !r->group ||
        !r->subgroup || !r->name || !r->int_value || !r->format || !r->state_count || !r->state_name ||
        !r->residency) {
        anemon_ior_close(r);
        return NULL;
    }
    return r;
}

anemon_ior *anemon_ior_open(void) {
    anemon_ior *r = ior_load();
    if (!r) return NULL;

    // ANEMON_NO_AMC=1 skips the AMC byte counters, to test the histogram
    // fallback on a machine that has them. ANEMON_CHANNELS=1 subscribes every
    // AMC Stats and PMP DCS BW channel and prints the active ones to stderr,
    // to find a new chip's channel names; the readings still use only the
    // known names.
    int no_amc = getenv("ANEMON_NO_AMC") != NULL;
    r->dump_channels = getenv("ANEMON_CHANNELS") != NULL;
    CFMutableDictionaryRef parts[] = {
        no_amc ? NULL : r->dump_channels ? usable(r, CFSTR("AMC Stats"), NULL, NULL)
                                         : usable(r, CFSTR("AMC Stats"), CFSTR("Perf Counters"), keep_ane_dcs),
        usable(r, CFSTR("PMP"), CFSTR("DCS BW"), r->dump_channels ? NULL : keep_ane_link),
        usable(r, CFSTR("PMP"), CFSTR("Energy"), keep_pcluster),
        usable(r, CFSTR("Interrupt Statistics (by index)"), NULL, NULL),
        usable(r, CFSTR("SoC Stats"), CFSTR("Events"), keep_soc_events),
        usable(r, CFSTR("ANE"), CFSTR("IOP State"), NULL),
        usable(r, CFSTR("ANE1"), CFSTR("IOP State"), NULL),
    };
    CFMutableDictionaryRef chans = NULL;
    for (size_t i = 0; i < sizeof parts / sizeof parts[0]; i++) {
        if (!parts[i]) continue;
        if (!chans) {
            chans = parts[i];
        } else {
            r->merge(chans, parts[i], NULL);
            CFRelease(parts[i]);
        }
    }
    if (!chans) {
        anemon_ior_close(r);
        return NULL;
    }
    r->sub = r->create_sub(NULL, chans, &r->subbed, 0, NULL);
    CFRelease(chans);
    if (!r->sub || !r->subbed) {
        anemon_ior_close(r);
        return NULL;
    }
    return r;
}

// Histogram states are named like "  32GB/s" or " 0.250W": the leading number.
static double state_value(anemon_ior *r, CFDictionaryRef ch, int32_t i) {
    char buf[64];
    cfstr(r->state_name(ch, i), buf, sizeof buf);
    return atof(buf);
}

// ANEMON_CHANNELS: one stderr line per active AMC Stats / PMP DCS BW channel
// and sample: a counter's delta, or a histogram's non-empty states.
static void dump_channel(anemon_ior *r, CFDictionaryRef ch, const char *grp, const char *sub, const char *name) {
    if (strcmp(grp, "AMC Stats") != 0 && !(strcmp(grp, "PMP") == 0 && strcmp(sub, "DCS BW") == 0)) return;
    if (r->format(ch) == 2) {
        char line[1024], state[64];
        int n = snprintf(line, sizeof line, "channel %s / %s / %s:", grp, sub, name), any = 0;
        for (int32_t j = 0; j < r->state_count(ch) && n < (int)sizeof line - 64; j++) {
            int64_t res = r->residency(ch, j);
            if (res <= 0) continue;
            cfstr(r->state_name(ch, j), state, sizeof state);
            n += snprintf(line + n, sizeof line - n, " [%s]=%lld", state, (long long)res);
            any = 1;
        }
        if (any) fprintf(stderr, "%s\n", line);
    } else {
        int64_t x = r->int_value(ch, 0);
        if (x > 0) fprintf(stderr, "channel %s / %s / %s: %lld\n", grp, sub, name, (long long)x);
    }
}

int anemon_ior_sample(anemon_ior *r, anemon_ior_values *v) {
    memset(v, 0, sizeof *v);
    CFDictionaryRef cur = r->create_samples(r->sub, r->subbed, NULL);
    if (!cur) return -1;
    if (!r->prev) {
        r->prev = cur;
        return 1;
    }
    CFDictionaryRef d = r->delta(r->prev, cur, NULL);
    CFRelease(r->prev);
    r->prev = cur;
    if (!d) return -1;

    CFArrayRef arr = CFDictionaryGetValue(d, CFSTR("IOReportChannels"));
    CFIndex n = arr ? CFArrayGetCount(arr) : 0;
    char grp[128], sub[128], name[128];
    for (CFIndex i = 0; i < n; i++) {
        CFDictionaryRef ch = CFArrayGetValueAtIndex(arr, i);
        cfstr(r->group(ch), grp, sizeof grp);
        cfstr(r->subgroup(ch), sub, sizeof sub);
        cfstr(r->name(ch), name, sizeof name);
        if (r->dump_channels) dump_channel(r, ch, grp, sub, name);
        // DCS = DRAM controller side; the AF (fabric) counters overlap with it.
        // Chips with two engines report each one; their traffic is summed.
        if (strcmp(grp, "AMC Stats") == 0 && is_ane_dcs(name)) {
            v->found |= ANEMON_IOR_DRAM;
            int64_t x = r->int_value(ch, 0);
            if (x <= 0) continue;
            size_t len = strlen(name);
            if (len >= 2 && strcmp(name + len - 2, "RD") == 0) v->dram_rd_bytes += (uint64_t)x;
            else if (len >= 2 && strcmp(name + len - 2, "WR") == 0) v->dram_wr_bytes += (uint64_t)x;
        } else if (strcmp(grp, "PMP") == 0 && strcmp(sub, "DCS BW") == 0 && r->format(ch) == 2) {
            // Each state is a GB/s bin named by its upper edge ("1GB/s" holds
            // an active but nearly idle link); residency counts samples taken
            // while the link was active. Sum of bin midpoint * count, per
            // direction. The top bin is open-ended and counted at its edge.
            int dir = ane_link_dir(name);
            if (!dir) continue;
            v->found |= ANEMON_IOR_DRAM_HIST;
            int32_t c = r->state_count(ch);
            uint64_t samples = 0;
            double lower = 0;
            for (int32_t j = 0; j < c; j++) {
                double upper = state_value(r, ch, j);
                double mid = j == c - 1 ? upper : (lower + upper) / 2;
                lower = upper;
                int64_t res = r->residency(ch, j);
                if (res <= 0) continue;
                samples += (uint64_t)res;
                double gbs = mid * (double)res;
                if (dir == 1) {
                    v->hist_rd += gbs;
                    if (j == c - 1) v->hist_rd_top += (uint64_t)res;
                } else {
                    v->hist_wr += gbs;
                }
            }
            if (dir == 1) {
                v->hist_rd_samples += samples;
                v->hist_links++;
            }
        } else if (strcmp(grp, "PMP") == 0 && strcmp(sub, "Energy") == 0 && r->format(ch) == 2 &&
                   is_pcluster(name)) {
            // Watt bins sampled continuously: the count-weighted mean is the
            // cluster's average power. Clusters and their SRAM are summed.
            v->found |= ANEMON_IOR_PCLUSTER;
            int32_t c = r->state_count(ch);
            double sum = 0, cnt = 0;
            for (int32_t j = 0; j < c; j++) {
                int64_t res = r->residency(ch, j);
                if (res <= 0) continue;
                sum += state_value(r, ch, j) * (double)res;
                cnt += (double)res;
            }
            if (cnt > 0) v->pcluster_w += sum / cnt;
        } else if (strcmp(grp, "SoC Stats") == 0 && strcmp(sub, "Events") == 0 && r->format(ch) == 2) {
            // Two states, INACT and ACT, in 24 MHz ticks.
            int lvl = dcs_level(name), kind = throttle_kind(name);
            if (lvl < 0 && kind < 0) continue;
            uint64_t act = 0, total = 0;
            char st[32];
            for (int32_t j = 0; j < r->state_count(ch); j++) {
                int64_t res = r->residency(ch, j);
                if (res <= 0) continue;
                total += (uint64_t)res;
                cfstr(r->state_name(ch, j), st, sizeof st);
                if (strcmp(st, "ACT") == 0) act += (uint64_t)res;
            }
            if (lvl >= 0) {
                v->found |= ANEMON_IOR_DCS_LEVELS;
                v->dcs_level_ticks[lvl] += act;
            } else {
                v->found |= ANEMON_IOR_THROTTLE;
                v->throttle_ticks[kind] += act;
                if (total > v->throttle_span_ticks) v->throttle_span_ticks = total;
            }
        } else if (strcmp(sub, "IOP State") == 0 && iop_engine(grp) >= 0 && r->format(ch) == 2) {
            int e = iop_engine(grp);
            v->found |= ANEMON_IOR_IOP;
            if (e + 1 > v->iop_engines) v->iop_engines = e + 1;
            char st[32];
            for (int32_t j = 0; j < r->state_count(ch); j++) {
                int64_t res = r->residency(ch, j);
                if (res <= 0) continue;
                cfstr(r->state_name(ch, j), st, sizeof st);
                int k = strcmp(st, "Off") == 0 ? ANEMON_IOP_OFF : strcmp(st, "Running") == 0 ? ANEMON_IOP_RUNNING : ANEMON_IOP_OTHER;
                v->iop_ticks[e][k] += (uint64_t)res;
            }
        } else if (strncmp(grp, "Interrupt Statistics", 20) == 0 && is_ane_irq(sub) &&
                   strstr(name, "First Level Interrupt Handler Count")) {
            v->found |= ANEMON_IOR_INTERRUPTS;
            int64_t x = r->int_value(ch, 0);
            if (x > 0) v->interrupts += (uint64_t)x;
        }
    }
    CFRelease(d);
    return 0;
}

void anemon_ior_close(anemon_ior *r) {
    if (!r) return;
    if (r->prev) CFRelease(r->prev);
    if (r->subbed) CFRelease(r->subbed);
    if (r->lib) dlclose(r->lib);
    free(r);
}

// ---- anemon diagnose ----------------------------------------------------

typedef CFDictionaryRef (*copy_all_fn)(uint64_t, uint64_t);

static void visit_channels(anemon_ior *r, CFDictionaryRef d, int with_values, anemon_ior_visit_fn fn, void *ctx) {
    CFArrayRef arr = CFDictionaryGetValue(d, CFSTR("IOReportChannels"));
    CFIndex n = arr ? CFArrayGetCount(arr) : 0;
    char grp[128], sub[128], name[128];
    for (CFIndex i = 0; i < n; i++) {
        CFDictionaryRef ch = CFArrayGetValueAtIndex(arr, i);
        cfstr(r->group(ch), grp, sizeof grp);
        cfstr(r->subgroup(ch), sub, sizeof sub);
        cfstr(r->name(ch), name, sizeof name);
        int fmt = r->format(ch);
        if (!with_values) {
            fn(ctx, grp, sub, name, fmt, 0, NULL, NULL);
        } else if (fmt == 1) {
            int64_t x = r->int_value(ch, 0);
            fn(ctx, grp, sub, name, fmt, 1, NULL, &x);
        } else if (fmt == 2) {
            int32_t c = r->state_count(ch);
            if (c <= 0) continue;
            if (c > 64) c = 64;
            char labels[64][48];
            const char *lp[64];
            int64_t vals[64];
            for (int32_t j = 0; j < c; j++) {
                cfstr(r->state_name(ch, j), labels[j], sizeof labels[j]);
                lp[j] = labels[j];
                vals[j] = r->residency(ch, j);
            }
            fn(ctx, grp, sub, name, fmt, c, lp, vals);
        } else {
            fn(ctx, grp, sub, name, fmt, 0, NULL, NULL);
        }
    }
}

int anemon_ior_list_all(anemon_ior_visit_fn fn, void *ctx) {
    anemon_ior *r = ior_load();
    if (!r) return -1;
    copy_all_fn copy_all = (copy_all_fn)dlsym(r->lib, "IOReportCopyAllChannels");
    CFDictionaryRef all = copy_all ? copy_all(0, 0) : NULL;
    if (!all) {
        anemon_ior_close(r);
        return -1;
    }
    visit_channels(r, all, 0, fn, ctx);
    CFRelease(all);
    anemon_ior_close(r);
    return 0;
}

anemon_ior *anemon_ior_open_all(int *unsubscribed) {
    *unsubscribed = 0;
    anemon_ior *r = ior_load();
    if (!r) return NULL;
    copy_all_fn copy_all = (copy_all_fn)dlsym(r->lib, "IOReportCopyAllChannels");
    CFDictionaryRef all = copy_all ? copy_all(0, 0) : NULL;
    if (!all) {
        anemon_ior_close(r);
        return NULL;
    }
    // Unique group / subgroup pairs, each subscribed on its own so that one
    // refused group does not silently drop the others from a merged set.
    CFMutableSetRef seen = CFSetCreateMutable(NULL, 0, &kCFTypeSetCallBacks);
    CFMutableDictionaryRef chans = NULL;
    CFArrayRef arr = CFDictionaryGetValue(all, CFSTR("IOReportChannels"));
    for (CFIndex i = 0; arr && i < CFArrayGetCount(arr); i++) {
        CFDictionaryRef ch = CFArrayGetValueAtIndex(arr, i);
        CFStringRef g = r->group(ch), s = r->subgroup(ch);
        if (!g) continue;
        CFStringRef key = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@\x1f%@"), g, s ? s : CFSTR(""));
        int fresh = !CFSetContainsValue(seen, key);
        if (fresh) CFSetAddValue(seen, key);
        CFRelease(key);
        if (!fresh) continue;
        CFMutableDictionaryRef part = usable(r, g, s, NULL);
        if (!part) {
            (*unsubscribed)++;
            continue;
        }
        if (!chans) {
            chans = part;
        } else {
            r->merge(chans, part, NULL);
            CFRelease(part);
        }
    }
    CFRelease(seen);
    CFRelease(all);
    if (!chans) {
        anemon_ior_close(r);
        return NULL;
    }
    r->sub = r->create_sub(NULL, chans, &r->subbed, 0, NULL);
    CFRelease(chans);
    if (!r->sub || !r->subbed) {
        anemon_ior_close(r);
        return NULL;
    }
    return r;
}

int anemon_ior_visit(anemon_ior *r, anemon_ior_visit_fn fn, void *ctx) {
    CFDictionaryRef cur = r->create_samples(r->sub, r->subbed, NULL);
    if (!cur) return -1;
    if (!r->prev) {
        r->prev = cur;
        return 1;
    }
    CFDictionaryRef d = r->delta(r->prev, cur, NULL);
    CFRelease(r->prev);
    r->prev = cur;
    if (!d) return -1;
    visit_channels(r, d, 1, fn, ctx);
    CFRelease(d);
    return 0;
}

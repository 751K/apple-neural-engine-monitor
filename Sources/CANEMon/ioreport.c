// ANE memory traffic and interrupt counters from the private IOReport
// library, loaded with dlopen so the binary does not need its stub.
// Works without root.

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

struct anemon_ior {
    void *lib;
    create_samples_fn create_samples;
    samples_delta_fn delta;
    get_str_fn group, subgroup, name;
    get_int_fn int_value;
    void *sub;
    CFMutableDictionaryRef subbed;
    CFDictionaryRef prev;
};

static int has_prefix_ci(const char *s, const char *p) { return strncasecmp(s, p, strlen(p)) == 0; }

static void cfstr(CFStringRef s, char *buf, size_t n) {
    buf[0] = 0;
    if (s) CFStringGetCString(s, buf, (CFIndex)n, kCFStringEncodingUTF8);
}

anemon_ior *anemon_ior_open(void) {
    void *lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY);
    if (!lib) return NULL;
    anemon_ior *r = calloc(1, sizeof(*r));
    r->lib = lib;
    copy_group_fn copy_group = (copy_group_fn)dlsym(lib, "IOReportCopyChannelsInGroup");
    merge_fn merge = (merge_fn)dlsym(lib, "IOReportMergeChannels");
    create_sub_fn create_sub = (create_sub_fn)dlsym(lib, "IOReportCreateSubscription");
    r->create_samples = (create_samples_fn)dlsym(lib, "IOReportCreateSamples");
    r->delta = (samples_delta_fn)dlsym(lib, "IOReportCreateSamplesDelta");
    r->group = (get_str_fn)dlsym(lib, "IOReportChannelGetGroup");
    r->subgroup = (get_str_fn)dlsym(lib, "IOReportChannelGetSubGroup");
    r->name = (get_str_fn)dlsym(lib, "IOReportChannelGetChannelName");
    r->int_value = (get_int_fn)dlsym(lib, "IOReportSimpleGetIntegerValue");
    if (!copy_group || !merge || !create_sub || !r->create_samples || !r->delta || !r->group ||
        !r->subgroup || !r->name || !r->int_value) {
        anemon_ior_close(r);
        return NULL;
    }

    CFMutableDictionaryRef chans = copy_group(CFSTR("AMC Stats"), CFSTR("Perf Counters"), 0, 0, 0);
    CFMutableDictionaryRef irq = copy_group(CFSTR("Interrupt Statistics (by index)"), NULL, 0, 0, 0);
    if (!chans) {
        chans = irq;
        irq = NULL;
    } else if (irq) {
        merge(chans, irq, NULL);
        CFRelease(irq);
    }
    if (!chans) {
        anemon_ior_close(r);
        return NULL;
    }
    r->sub = create_sub(NULL, chans, &r->subbed, 0, NULL);
    CFRelease(chans);
    if (!r->sub || !r->subbed) {
        anemon_ior_close(r);
        return NULL;
    }
    return r;
}

int anemon_ior_sample(anemon_ior *r, uint64_t *rd, uint64_t *wr, uint64_t *irqs) {
    *rd = *wr = *irqs = 0;
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
        // DCS = DRAM controller side; the AF (fabric) counters overlap with it.
        if (strcmp(grp, "AMC Stats") == 0 && has_prefix_ci(name, "ANE DCS ")) {
            int64_t v = r->int_value(ch, 0);
            if (v <= 0) continue;
            size_t len = strlen(name);
            if (len >= 2 && strcmp(name + len - 2, "RD") == 0) *rd += (uint64_t)v;
            else if (len >= 2 && strcmp(name + len - 2, "WR") == 0) *wr += (uint64_t)v;
        } else if (strncmp(grp, "Interrupt Statistics", 20) == 0 && has_prefix_ci(sub, "ane ") &&
                   strstr(name, "First Level Interrupt Handler Count")) {
            int64_t v = r->int_value(ch, 0);
            if (v > 0) *irqs += (uint64_t)v;
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

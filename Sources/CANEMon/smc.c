// Reads float keys from the System Management Controller through the
// AppleSMC user client. Power rails are exposed as "P..." keys in watts;
// which rail feeds which block differs between chips.

#include "canemon.h"

#include <IOKit/IOKitLib.h>
#include <string.h>

// Layout of the AppleSMC struct method argument (80 bytes; field alignment
// matters, so keep the nested structs).
typedef struct { char major, minor, build, reserved; uint16_t release; } smc_vers;
typedef struct { uint16_t version, length; uint32_t cpu, gpu, mem; } smc_plimit;
typedef struct { uint32_t size, type; uint8_t attr; } smc_info;
typedef struct {
    uint32_t key;
    smc_vers vers;
    smc_plimit plimit;
    smc_info info;
    uint8_t result, status, cmd;
    uint32_t data32;
    uint8_t bytes[32];
} smc_msg;
_Static_assert(sizeof(smc_msg) == 80, "AppleSMC message layout");

enum { SMC_READ_BYTES = 5, SMC_READ_INFO = 9, SMC_SELECTOR = 2 };

static io_connect_t conn;

int anemon_smc_open(void) {
    if (conn) return 0;
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return -1;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    IOObjectRelease(svc);
    if (kr != KERN_SUCCESS) conn = 0;
    return conn ? 0 : -1;
}

static int call(smc_msg *in, smc_msg *out) {
    size_t sz = sizeof *out;
    memset(out, 0, sizeof *out);
    return IOConnectCallStructMethod(conn, SMC_SELECTOR, in, sizeof *in, out, &sz) == KERN_SUCCESS &&
                   out->result == 0 ? 0 : -1;
}

int anemon_smc_read_float(const char *key, float *value) {
    if (!conn || strlen(key) != 4) return -1;
    smc_msg in = {0}, out;
    in.key = (uint32_t)key[0] << 24 | (uint32_t)key[1] << 16 | (uint32_t)key[2] << 8 | (uint32_t)key[3];
    in.cmd = SMC_READ_INFO;
    if (call(&in, &out) || out.info.size != 4 || out.info.type != ('f' << 24 | 'l' << 16 | 't' << 8 | ' '))
        return -1;
    in.info.size = 4;
    in.cmd = SMC_READ_BYTES;
    if (call(&in, &out)) return -1;
    memcpy(value, out.bytes, 4);
    return 0;
}

void anemon_smc_close(void) {
    if (conn) IOServiceClose(conn);
    conn = 0;
}

// See smc.h. The AppleSMC user client takes an 80-byte parameter block through
// IOConnectCallStructMethod selector 2; byte layout verified on M1 Pro / macOS 26.
#include "smc.h"

#include <CoreAudio/CoreAudio.h>
#include <IOKit/IOKitLib.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <signal.h>
#include <string.h>
#include <sys/proc_info.h>
#include <unistd.h>

#ifndef PROC_FLAG_DARWINBG
#define PROC_FLAG_DARWINBG     0x8000   // private in the SDK headers
#endif
#ifndef PROC_FLAG_EXT_DARWINBG
#define PROC_FLAG_EXT_DARWINBG 0x10000
#endif

enum { SMC_SELECTOR = 2, CMD_READ_BYTES = 5, CMD_WRITE_BYTES = 6, CMD_READ_KEYINFO = 9 };

typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } smc_vers;
typedef struct { uint16_t version, length; uint32_t cpu, gpu, mem; } smc_plimit;
typedef struct { uint32_t data_size, data_type; uint8_t attributes; } smc_keyinfo;
typedef struct {
    uint32_t key;
    smc_vers vers;
    smc_plimit plimit;
    smc_keyinfo info;
    uint8_t result, status, data8;
    uint32_t data32;
    uint8_t bytes[32];
} smc_param;
_Static_assert(sizeof(smc_param) == 80, "AppleSMC parameter block must be 80 bytes");

static io_connect_t g_conn = IO_OBJECT_NULL;

// IOKit error codes (0xe00002xx) are negative as int; keep them negative.
static int kerr(kern_return_t kr) { return kr < 0 ? kr : -kr; }

static int fourcc(const char *key, uint32_t *out) {
    if (!key || strlen(key) != 4) return -1;
    *out = (uint32_t)(uint8_t)key[0] << 24 | (uint32_t)(uint8_t)key[1] << 16 |
           (uint32_t)(uint8_t)key[2] << 8 | (uint32_t)(uint8_t)key[3];
    return 0;
}

static int call(const smc_param *in, smc_param *out) {
    if (g_conn == IO_OBJECT_NULL) return kerr(kIOReturnNotOpen);
    size_t out_size = sizeof *out;
    memset(out, 0, sizeof *out);
    kern_return_t kr = IOConnectCallStructMethod(g_conn, SMC_SELECTOR, in, sizeof *in, out, &out_size);
    if (kr != KERN_SUCCESS) return kerr(kr);
    return out->result;
}

int bt_smc_open(void) {
    if (g_conn != IO_OBJECT_NULL) return 0;
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (svc == IO_OBJECT_NULL) return kerr(kIOReturnNotFound);
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &g_conn);
    IOObjectRelease(svc);
    if (kr != KERN_SUCCESS) { g_conn = IO_OBJECT_NULL; return kerr(kr); }
    return 0;
}

void bt_smc_close(void) {
    if (g_conn != IO_OBJECT_NULL) IOServiceClose(g_conn);
    g_conn = IO_OBJECT_NULL;
}

int bt_smc_key_info(const char *key, uint32_t *size_out, char type_out[5]) {
    smc_param in = {0}, out;
    if (fourcc(key, &in.key)) return kerr(kIOReturnBadArgument);
    in.data8 = CMD_READ_KEYINFO;
    int r = call(&in, &out);
    if (r) return r;
    if (size_out) *size_out = out.info.data_size;
    if (type_out) {
        uint32_t t = out.info.data_type;
        type_out[0] = (char)(t >> 24); type_out[1] = (char)(t >> 16);
        type_out[2] = (char)(t >> 8);  type_out[3] = (char)t; type_out[4] = 0;
    }
    return 0;
}

int bt_smc_read(const char *key, uint8_t *buf, uint32_t bufsize, uint32_t *size_out) {
    uint32_t size = 0;
    int r = bt_smc_key_info(key, &size, NULL);
    if (r) return r;
    if (size > 32 || size > bufsize) return kerr(kIOReturnNoSpace);
    smc_param in = {0}, out;
    fourcc(key, &in.key);
    in.info.data_size = size;
    in.data8 = CMD_READ_BYTES;
    r = call(&in, &out);
    if (r) return r;
    memcpy(buf, out.bytes, size);
    if (size_out) *size_out = size;
    return 0;
}

static pthread_mutex_t g_write_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_stopping = 0;

static int all_zero(const uint8_t *data, uint32_t size) {
    for (uint32_t i = 0; i < size; i++) if (data[i]) return 0;
    return 1;
}

int bt_smc_write(const char *key, const uint8_t *data, uint32_t size) {
    uint32_t expected = 0;
    int r = bt_smc_key_info(key, &expected, NULL);
    if (r) return r;
    if (size != expected || size > 32) return kerr(kIOReturnBadArgument);
    smc_param in = {0}, out;
    fourcc(key, &in.key);
    in.info.data_size = size;
    in.data8 = CMD_WRITE_BYTES;
    memcpy(in.bytes, data, size);
    pthread_mutex_lock(&g_write_lock);
    r = g_stopping && !all_zero(data, size) ? BT_SMC_REFUSED : call(&in, &out);
    pthread_mutex_unlock(&g_write_lock);
    return r;
}

// ---- crash path -------------------------------------------------------------

static smc_param g_emergency[4];
static volatile sig_atomic_t g_emergency_count = 0;

int bt_smc_emergency_add(const char *key, const uint8_t *enable_bytes, uint32_t size) {
    if (g_emergency_count >= 4 || size == 0 || size > 32) return -1;
    smc_param p = {0};
    if (fourcc(key, &p.key)) return -1;
    p.info.data_size = size;
    p.data8 = CMD_WRITE_BYTES;
    memcpy(p.bytes, enable_bytes, size);
    g_emergency[g_emergency_count] = p;
    g_emergency_count = g_emergency_count + 1;
    return 0;
}

void bt_smc_emergency_enable(void) {
    if (g_conn == IO_OBJECT_NULL) return;
    for (int i = 0; i < g_emergency_count; i++) {
        smc_param out;
        size_t out_size = sizeof out;
        IOConnectCallStructMethod(g_conn, SMC_SELECTOR, &g_emergency[i], sizeof g_emergency[i], &out, &out_size);
    }
}

void bt_smc_stop(void) {
    pthread_mutex_lock(&g_write_lock);
    g_stopping = 1;
    bt_smc_emergency_enable();
    pthread_mutex_unlock(&g_write_lock);
}

static void crash_handler(int sig) {
    bt_smc_emergency_enable();
    static const char msg[] = "battery-tool: fatal signal; emergency charging re-enable issued\n";
    (void)!write(STDERR_FILENO, msg, sizeof msg - 1);
    signal(sig, SIG_DFL);
    raise(sig);
}

void bt_install_crash_handlers(void) {
    static char alt_stack[1 << 17];
    stack_t ss = { .ss_sp = alt_stack, .ss_size = sizeof alt_stack, .ss_flags = 0 };
    sigaltstack(&ss, NULL);
    const int sigs[] = { SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP, SIGABRT, SIGSYS };
    for (size_t i = 0; i < sizeof sigs / sizeof sigs[0]; i++) {
        struct sigaction sa;
        memset(&sa, 0, sizeof sa);
        sa.sa_handler = crash_handler;
        sa.sa_flags = SA_ONSTACK | SA_RESETHAND | SA_NODEFER;
        sigemptyset(&sa.sa_mask);
        sigaction(sigs[i], &sa, NULL);
    }
}

// ---- processes --------------------------------------------------------------

int bt_list_pids(int32_t *buf, int max) {
    if (max <= 0) return 0;
    int n = proc_listallpids(buf, max * (int)sizeof(int32_t));
    return n > max ? max : n;
}

int bt_proc_info(int32_t pid, bt_procinfo *out) {
    struct proc_bsdinfo bi;
    memset(out, 0, sizeof *out);
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, sizeof bi) != (int)sizeof bi) return -1;
    out->pid = pid;
    out->ppid = (int32_t)bi.pbi_ppid;
    out->uid = bi.pbi_uid;
    out->start_sec = bi.pbi_start_tvsec;
    out->start_usec = bi.pbi_start_tvusec;
    out->flags = bi.pbi_flags;
    out->ext_darwin_bg = (bi.pbi_flags & PROC_FLAG_EXT_DARWINBG) ? 1 : 0;
    out->darwin_bg = (bi.pbi_flags & (PROC_FLAG_DARWINBG | PROC_FLAG_EXT_DARWINBG)) ? 1 : 0;
    out->exiting = (bi.pbi_flags & PROC_FLAG_INEXIT) ? 1 : 0;
    out->nice = bi.pbi_nice;
    strlcpy(out->name, bi.pbi_name[0] ? bi.pbi_name : bi.pbi_comm, sizeof out->name);

    struct proc_taskinfo ti;
    if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, sizeof ti) == (int)sizeof ti) {
        out->priority = ti.pti_priority;
        static mach_timebase_info_data_t tb;                // pti_total_* are mach ticks on Apple Silicon
        if (tb.denom == 0) mach_timebase_info(&tb);
        out->cpu_ns = (ti.pti_total_user + ti.pti_total_system) * tb.numer / tb.denom;
    } else {
        out->priority = -1;
    }
    if (proc_pidpath(pid, out->path, sizeof out->path) <= 0) out->path[0] = 0;
    return 0;
}

// ---- audio ------------------------------------------------------------------

int bt_audio_output_pids(int32_t *buf, int max, int *objects_out) {
    AudioObjectPropertyAddress list = { kAudioHardwarePropertyProcessObjectList,
                                        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    if (objects_out) *objects_out = 0;
    OSStatus st = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &list, 0, NULL, &size);
    if (st != noErr) return st < 0 ? st : -st;
    UInt32 count = size / sizeof(AudioObjectID);
    if (count == 0) return 0;
    AudioObjectID ids[512];
    if (count > 512) count = 512;
    size = count * sizeof(AudioObjectID);
    st = AudioObjectGetPropertyData(kAudioObjectSystemObject, &list, 0, NULL, &size, ids);
    if (st != noErr) return st < 0 ? st : -st;
    count = size / sizeof(AudioObjectID);
    if (objects_out) *objects_out = (int)count;
    int n = 0, failures = 0;
    OSStatus last = noErr;
    for (UInt32 i = 0; i < count && n < max; i++) {
        AudioObjectPropertyAddress out = { kAudioProcessPropertyIsRunningOutput,
                                           kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        UInt32 running = 0, sz = sizeof running;
        st = AudioObjectGetPropertyData(ids[i], &out, 0, NULL, &sz, &running);
        if (st != noErr) { failures++; last = st; continue; }   // an object that vanished mid-walk is normal
        if (!running) continue;
        AudioObjectPropertyAddress pidp = { kAudioProcessPropertyPID,
                                            kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        pid_t pid = 0;
        sz = sizeof pid;
        if (AudioObjectGetPropertyData(ids[i], &pidp, 0, NULL, &sz, &pid) != noErr || pid <= 1) continue;
        buf[n++] = pid;
    }
    // Every object refused the property: the API is not working for this process (fail safe).
    if (failures > 0 && (UInt32)failures == count) return last < 0 ? last : -(last ? last : 1);
    return n;
}

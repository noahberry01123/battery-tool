// Low-level helpers for battery-tool: AppleSMC key access, crash-path charging
// re-enable, and process inspection (libproc). Written from the public IOKit
// AppleSMC user-client interface; no third-party code.
#ifndef BT_SMC_H
#define BT_SMC_H

#include <stdint.h>

// Error convention for the bt_smc_* functions: 0 = success,
// negative = IOKit kern_return_t (negated), positive = SMC result byte
// (132 / 0x84 = key not found).
#define BT_SMC_KEY_NOT_FOUND 132

int  bt_smc_open(void);
void bt_smc_close(void);
int  bt_smc_key_info(const char *key, uint32_t *size_out, char type_out[5]);
int  bt_smc_read(const char *key, uint8_t *buf, uint32_t bufsize, uint32_t *size_out);
int  bt_smc_write(const char *key, const uint8_t *data, uint32_t size);

// Crash path. Register (up to 4) "charging enabled" values ahead of time; the
// crash handlers then replay them with prebuilt requests on the already-open
// connection (no allocation, no locks), print a note to stderr, and re-raise.
int  bt_smc_emergency_add(const char *key, const uint8_t *enable_bytes, uint32_t size);
void bt_smc_emergency_enable(void);
void bt_install_crash_handlers(void);

// SIGTERM path (thread context, not a signal handler): from now on refuse every write
// whose bytes are not all zero (every "charging enabled" value is all zero), then
// replay the emergency writes. Shares bt_smc_write's lock, so an inhibit already in
// flight finishes first and is then overwritten.
#define BT_SMC_REFUSED 254
void bt_smc_stop(void);

// Process inspection.
#define BT_PATH_MAX 4096
typedef struct {
    int32_t  pid;
    int32_t  ppid;
    uint32_t uid;          // effective uid
    uint64_t start_sec;    // process start time, epoch seconds
    uint64_t start_usec;
    uint32_t flags;        // raw pbi_flags
    int32_t  ext_darwin_bg;// 1 if externally placed in darwin background (taskpolicy -b -p / setpriority)
    int32_t  darwin_bg;    // 1 if in darwin background for any reason (internal or external)
    int32_t  exiting;      // 1 if the process is exiting
    int32_t  nice;         // nice value
    int32_t  priority;     // base scheduling priority (31 normal, 4 darwin-bg), -1 if unknown
    uint64_t cpu_ns;       // total user + system CPU time, nanoseconds (0 if unknown)
    char     name[64];     // short name (pbi_name, falls back to pbi_comm)
    char     path[BT_PATH_MAX]; // executable path (proc_pidpath), "" if unavailable
} bt_procinfo;

// Audio: pids of processes CoreAudio reports as running output right now
// (kAudioHardwarePropertyProcessObjectList, macOS 14.2+). Returns the count written
// to buf, or a negative OSStatus if the list cannot be read. objects_out = size of
// the process object list (0 when CoreAudio has no process objects at all).
int bt_audio_output_pids(int32_t *buf, int max, int *objects_out);

// Fills buf with up to max pids; returns the number written (<= 0 on error).
int bt_list_pids(int32_t *buf, int max);
// 0 on success, -1 if the process is gone or not inspectable.
int bt_proc_info(int32_t pid, bt_procinfo *out);

#endif

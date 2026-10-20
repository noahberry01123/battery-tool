// telemetry <interval_ms> <count|0>: read-only SMC sampler, one CSV row per interval.
// Columns: epoch, system power (PSTR, W), battery power (PPBR, W), hottest CPU sensor (Tp*),
// hottest GPU sensor (Tg05/Tg0D), battery sensors TB0T/TB1T, Ts0P/Ts1P (community-identified as
// palm-rest area; unverified), fan 0/1 actual RPM. A key that cannot be read prints as empty.
// Uses battery-tool's own SMC reader (Sources/CSMC/smc.c); never writes the SMC.
#include "../../Sources/CSMC/smc.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>

static int rd(const char *key, double *v) {
    uint8_t b[32]; uint32_t n = 0; char type[5] = {0}; uint32_t sz;
    if (bt_smc_key_info(key, &sz, type) != 0 || bt_smc_read(key, b, sizeof b, &n) != 0) return 0;
    if (!strcmp(type, "flt ") && n == 4) { float f; memcpy(&f, b, 4); *v = f; return 1; }
    return 0;
}
static const char *CPU[] = {"Tp01","Tp05","Tp09","Tp0D","Tp0H","Tp0L","Tp0P","Tp0T","Tp0X","Tp0b",
                            "Tp02","Tp06","Tp0A","Tp0E","Tp0I","Tp0M","Tp0Q","Tp0U","Tp0Y","Tp0c",NULL};
static const char *GPU[] = {"Tg05","Tg0D",NULL};
static void maxof(const char **keys, char *out) {
    double m = -1, v; for (int i = 0; keys[i]; i++) if (rd(keys[i], &v) && v > 0 && v < 130 && v > m) m = v;
    if (m < 0) out[0] = 0; else sprintf(out, "%.2f", m);
}
static void one(const char *key, char *out) { double v; if (rd(key, &v)) sprintf(out, "%.2f", v); else out[0] = 0; }

int main(int argc, char **argv) {
    int ms = argc > 1 ? atoi(argv[1]) : 1000; long count = argc > 2 ? atol(argv[2]) : 0;
    if (bt_smc_open() != 0) { fprintf(stderr, "cannot open AppleSMC\n"); return 1; }
    setvbuf(stdout, NULL, _IOLBF, 0);
    printf("epoch,system_w,battery_w,cpu_max_c,gpu_max_c,batt0_c,batt1_c,palm0_c,palm1_c,fan0_rpm,fan1_rpm\n");
    const char *keys[] = {"PSTR","PPBR",NULL,NULL,"TB0T","TB1T","Ts0P","Ts1P","F0Ac","F1Ac"};
    for (long i = 0; count == 0 || i < count; i++) {
        struct timeval tv; gettimeofday(&tv, NULL);
        char f[10][16];
        for (int k = 0; k < 10; k++) {
            if (k == 2) maxof(CPU, f[k]); else if (k == 3) maxof(GPU, f[k]); else one(keys[k], f[k]);
        }
        printf("%.3f", tv.tv_sec + tv.tv_usec / 1e6);
        for (int k = 0; k < 10; k++) printf(",%s", f[k]);
        printf("\n");
        usleep(ms * 1000);
    }
}

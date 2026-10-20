// proccores: snapshot of every process this user may inspect, one CSV row each:
// pid, start time, uid, externally darwin-background flag, total CPU time, CPU time on P-cores,
// CPU time at background QoS, energy (all from proc_pid_rusage RUSAGE_INFO_V6), name.
// Deltas between two snapshots give each process's P-core share over a window.
// Processes of other users fail with EPERM unless run as root; they are counted, not guessed.
#include "../../Sources/CSMC/smc.h"
#include <libproc.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <sys/resource.h>
#include <sys/time.h>

int main(void) {
    static int32_t pids[16384]; int n = bt_list_pids(pids, 16384), denied = 0;
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    double k = (double)tb.numer / tb.denom;          // mach ticks -> ns
    struct timeval tv; gettimeofday(&tv, NULL);
    printf("# epoch %.3f\n", tv.tv_sec + tv.tv_usec / 1e6);
    printf("pid,start_sec,uid,ext_darwin_bg,cpu_ns,pcore_ns,qos_bg_ns,energy_nj,name\n");
    for (int i = 0; i < n; i++) {
        bt_procinfo p; struct rusage_info_v6 ri;
        if (pids[i] <= 0 || bt_proc_info(pids[i], &p) != 0) continue;
        if (proc_pid_rusage(pids[i], RUSAGE_INFO_V6, (rusage_info_t *)&ri) != 0) { denied++; continue; }
        printf("%d,%llu,%u,%d,%.0f,%.0f,%.0f,%llu,\"%s\"\n", p.pid, (unsigned long long)p.start_sec, p.uid,
               p.ext_darwin_bg, (ri.ri_user_time + ri.ri_system_time) * k, (ri.ri_user_ptime + ri.ri_system_ptime) * k,
               ri.ri_cpu_time_qos_background * k, (unsigned long long)ri.ri_energy_nj, p.name);
    }
    printf("# not_inspectable %d\n", denied);
}

#define _GNU_SOURCE
#include "include/CAbeliaSignals.h"

#include <unistd.h>
#ifdef __APPLE__
#include <pthread.h>
#endif

CSIGNALS_TLS void *csignals_active_sub = 0;
CSIGNALS_TLS uint64_t csignals_cycle = 0;
CSIGNALS_TLS uint32_t csignals_run_depth = 0;
CSIGNALS_TLS uint32_t csignals_walk_depth = 0;
CSIGNALS_TLS void *csignals_deferred_links = 0;

// Exported by the Swift concurrency runtime, but not public API, and Swift
// warns when it's named with @_silgen_name, so it's called from here.
extern __attribute__((swiftcall)) csignals_executor swift_task_getCurrentExecutor(void);
// flags 0: answer false instead of crashing, as Task.immediate does
extern __attribute__((swiftcall)) bool swift_task_isCurrentExecutorWithFlags(
    csignals_executor executor, uint64_t flags);

csignals_executor csignals_current_executor(void) { return swift_task_getCurrentExecutor(); }

bool csignals_is_current_executor(csignals_executor executor) {
    return swift_task_isCurrentExecutorWithFlags(executor, 0);
}

bool csignals_is_main_thread(void) {
#ifdef __APPLE__
    return pthread_main_np() != 0;
#else
    return gettid() == getpid();
#endif
}

#define _GNU_SOURCE // gettid
#include "AbeliaSignalsTLS.h"

#if defined(_WIN32)
#include <windows.h>
#else
#include <pthread.h>
#include <unistd.h>
#endif

_Thread_local void *abelia_tls_current_sink ABELIA_TLS_MODEL = 0;
_Thread_local void *abelia_tls_immediate_batch ABELIA_TLS_MODEL = 0;
_Thread_local void *abelia_tls_current_scope ABELIA_TLS_MODEL = 0;
_Thread_local void *abelia_tls_current_scheduler ABELIA_TLS_MODEL = 0;

// Swift concurrency runtime entry points (swiftcc).
// For debug only
typedef struct {
  const void *identity; // NULL: global executor
  uintptr_t implementation;
} AbeliaExecutorRef;
extern AbeliaExecutorRef swift_task_getCurrentExecutor(void)
    __attribute__((swiftcall));
extern AbeliaExecutorRef swift_task_getMainExecutor(void)
    __attribute__((swiftcall));
extern void *swift_task_getCurrent(void) __attribute__((swiftcall));

#define ABELIA_MAIN_KEY ((uintptr_t)1)

#if defined(_WIN32)
static uintptr_t current_thread(void) {
  return (uintptr_t)GetCurrentThreadId();
}

// no API for it: static init runs on the main thread at startup
static uintptr_t main_thread;
__attribute__((constructor)) static void record_main_thread(void) {
  main_thread = current_thread();
}
static int is_main_thread(void) { return current_thread() == main_thread; }
#else
static uintptr_t current_thread(void) { return (uintptr_t)pthread_self(); }

static int is_main_thread(void) {
#if defined(__APPLE__)
  return pthread_main_np();
#else
  return getpid() == gettid();
#endif
}
#endif

uintptr_t abelia_current_isolation_key(void) {
  const void *current = swift_task_getCurrentExecutor().identity;
  if (current) {
    return current == swift_task_getMainExecutor().identity
               ? ABELIA_MAIN_KEY
               : (uintptr_t)current;
  }
  if (swift_task_getCurrent())
    return 0; // may hop threads
  return is_main_thread() ? ABELIA_MAIN_KEY : current_thread();
}

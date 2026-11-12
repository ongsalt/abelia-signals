#ifndef ABELIA_SIGNALS_TLS_H
#define ABELIA_SIGNALS_TLS_H

// initial-exec: one %fs-relative access instead of a __tls_get_addr call, also when this is
// built into a shared library (an executable gets that anyway). Not for a library dlopen'd later.
// ELF only, Mach-O thread-locals have their own access path.
#if defined(__ELF__)
#define ABELIA_TLS_MODEL __attribute__((tls_model("initial-exec")))
#else
#define ABELIA_TLS_MODEL
#endif

extern _Thread_local void *_Nullable abelia_tls_current_sink ABELIA_TLS_MODEL;
extern _Thread_local void *_Nullable abelia_tls_immediate_batch ABELIA_TLS_MODEL;
extern _Thread_local void *_Nullable abelia_tls_current_scope ABELIA_TLS_MODEL;

#endif

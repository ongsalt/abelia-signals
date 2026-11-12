#include "AbeliaSignalsTLS.h"

_Thread_local void *abelia_tls_current_sink ABELIA_TLS_MODEL = 0;
_Thread_local void *abelia_tls_immediate_batch ABELIA_TLS_MODEL = 0;
_Thread_local void *abelia_tls_current_scope ABELIA_TLS_MODEL = 0;


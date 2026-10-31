#include "CAbeliaSignals.h"

CSIGNALS_TLS void *csignals_active_sub = 0;
CSIGNALS_TLS uint64_t csignals_cycle = 0;
CSIGNALS_TLS uint32_t csignals_run_depth = 0;
CSIGNALS_TLS uint32_t csignals_walk_depth = 0;
CSIGNALS_TLS void *csignals_deferred_links = 0;

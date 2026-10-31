#pragma once

#include <stdint.h>

// Tracking state for Signals. Swift has no native thread-locals.
#define CSIGNALS_TLS __attribute__((tls_model("initial-exec"))) _Thread_local

extern CSIGNALS_TLS void *_Nullable csignals_active_sub;
extern CSIGNALS_TLS uint64_t csignals_cycle;
extern CSIGNALS_TLS uint32_t csignals_run_depth;
// checkDirty walks in progress; links unlinked meanwhile wait in the deferred list
extern CSIGNALS_TLS uint32_t csignals_walk_depth;
extern CSIGNALS_TLS void *_Nullable csignals_deferred_links;

static inline void *_Nullable csignals_get_active_sub(void) { return csignals_active_sub; }
static inline void csignals_set_active_sub(void *_Nullable sub) { csignals_active_sub = sub; }

static inline uint64_t csignals_get_cycle(void) { return csignals_cycle; }
static inline uint64_t csignals_next_cycle(void) { return ++csignals_cycle; }

static inline uint32_t csignals_get_run_depth(void) { return csignals_run_depth; }
static inline void csignals_set_run_depth(uint32_t depth) { csignals_run_depth = depth; }

static inline uint32_t csignals_get_walk_depth(void) { return csignals_walk_depth; }
static inline void csignals_set_walk_depth(uint32_t depth) { csignals_walk_depth = depth; }

static inline void *_Nullable csignals_get_deferred_links(void) { return csignals_deferred_links; }
static inline void csignals_set_deferred_links(void *_Nullable link) { csignals_deferred_links = link; }

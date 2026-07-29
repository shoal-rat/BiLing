#ifndef BILING_LLAMA_H
#define BILING_LLAMA_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct BiLingLlama BiLingLlama;

// Return codes shared by the scoring entry points. Any other negative value
// is an unrecoverable request failure described via the error buffer.
#define BILING_LLAMA_OK 0
#define BILING_LLAMA_CANCELLED (-2)
#define BILING_LLAMA_TIMED_OUT (-8)

// adapter_path may be NULL or empty for no LoRA adapter. A failing adapter
// load is non-fatal: the model comes up without it and the description says
// so. adapter_scale is the LoRA strength (1.0 = as trained). The GGUF file is
// treated as untrusted input: any load or validation failure returns NULL
// with a message in `error`.
BiLingLlama * biling_llama_open(
    const char * model_path,
    const char * adapter_path,
    float adapter_scale,
    char * error,
    size_t error_size
);
void biling_llama_close(BiLingLlama * instance);

// Scores each candidate by the log-probability of its token suffix after the
// committed context. (context + candidate) is tokenized as one merged string
// so BPE merges across the join are handled; only the tokens past the longest
// common token prefix with the context are priced. Candidate continuations
// share the context's KV prefix and are decoded in batched waves.
//
// timeout_ms is a wall-clock budget for the whole call (<= 0 disables it).
// Returns BILING_LLAMA_OK on success, BILING_LLAMA_CANCELLED when
// biling_llama_cancel superseded the call, BILING_LLAMA_TIMED_OUT when the
// budget expired; both interrupts abort mid-decode within milliseconds.
int biling_llama_score(
    BiLingLlama * instance,
    const char * context,
    const char * const * candidates,
    int candidate_count,
    long timeout_ms,
    float * scores,
    char * error,
    size_t error_size
);

// Async-signal-safe-ish cancellation: sets an atomic flag read by the scoring
// loop and by llama.cpp's abort callback. Safe to call from any thread while
// a score call is running. The caller must reset the flag (under the same
// lock that decides which request is active) before starting the next call.
void biling_llama_cancel(BiLingLlama * instance);
void biling_llama_reset_cancel(BiLingLlama * instance);
const char * biling_llama_description(BiLingLlama * instance);

#ifdef __cplusplus
}
#endif

#endif

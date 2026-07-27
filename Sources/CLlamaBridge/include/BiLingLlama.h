#ifndef BILING_LLAMA_H
#define BILING_LLAMA_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct BiLingLlama BiLingLlama;

// adapter_path may be NULL or empty for no LoRA adapter. A failing adapter
// load is non-fatal: the model comes up without it and the description says
// so. adapter_scale is the LoRA strength (1.0 = as trained).
BiLingLlama * biling_llama_open(
    const char * model_path,
    const char * adapter_path,
    float adapter_scale,
    char * error,
    size_t error_size
);
void biling_llama_close(BiLingLlama * instance);

// Scores each candidate by its complete canonical token path after context.
// Candidate continuations are decoded in one multi-sequence batch with a shared
// KV prefix, so this remains one context pass plus one batched continuation pass.
int biling_llama_score(
    BiLingLlama * instance,
    const char * context,
    const char * const * candidates,
    int candidate_count,
    float * scores,
    char * error,
    size_t error_size
);

void biling_llama_cancel(BiLingLlama * instance);
void biling_llama_reset_cancel(BiLingLlama * instance);
const char * biling_llama_description(BiLingLlama * instance);

#ifdef __cplusplus
}
#endif

#endif

#include "BiLingLlama.h"

#include <Accelerate/Accelerate.h>
#include <llama.h>
#include <math.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

// The committed context is re-sent on every keystroke, but between keystrokes it
// is either identical or extended. Sequence 0 keeps the context's KV cells alive
// across requests, so only new suffix tokens are ever decoded. The context is
// trimmed with hysteresis (drop to KEEP once it exceeds LIMIT) so the retained
// prefix stays byte-stable between trims and the cache keeps hitting.
#define BILING_CONTEXT_LIMIT 1300
#define BILING_CONTEXT_KEEP 900

// Must match context_params.n_seq_max below. Sequence 0 is the committed
// context; sequences 1..(BILING_MAX_SEQUENCES - 1) are candidate scratch.
#define BILING_MAX_SEQUENCES 48

struct BiLingLlama {
    struct llama_model * model;
    struct llama_context * context;
    const struct llama_vocab * vocab;
    struct llama_adapter_lora * adapter;
    // Written from the caller's cancel thread, read from the scoring thread and
    // from llama.cpp's abort callback mid-graph: must be a real atomic, not
    // `volatile`, so the cross-thread visibility is guaranteed.
    _Atomic bool cancelled;
    // Monotonic-clock deadline for the in-flight scoring call, in nanoseconds.
    // Zero means no deadline. Set/cleared by biling_llama_score around the
    // work, read by the abort callback.
    _Atomic uint64_t deadline_ns;
    char description[256];

    // Cached state of sequence 0 (the committed context).
    llama_token * cached_tokens;
    int cached_count;
    int cached_capacity;
    bool cache_valid;
    float * cached_logits;      // next-token logits after the cached context
    double cached_logsumexp;
    float * scratch;            // vDSP workspace, vocabulary-sized
};

static void write_error(char * target, size_t size, const char * message) {
    if (target == NULL || size == 0) {
        return;
    }
    snprintf(target, size, "%s", message);
}

static uint64_t monotonic_ns(void) {
    return clock_gettime_nsec_np(CLOCK_MONOTONIC);
}

// Returns 0 to keep going, or the error code the caller should surface:
// BILING_LLAMA_CANCELLED when a newer request superseded this one,
// BILING_LLAMA_TIMED_OUT when the wall-clock budget ran out. Cancellation is
// checked first so an explicit cancel is reported as such even after expiry.
static int interrupt_code(struct BiLingLlama * instance) {
    if (atomic_load_explicit(&instance->cancelled, memory_order_relaxed)) {
        return BILING_LLAMA_CANCELLED;
    }
    const uint64_t deadline = atomic_load_explicit(&instance->deadline_ns, memory_order_relaxed);
    if (deadline != 0 && monotonic_ns() >= deadline) {
        return BILING_LLAMA_TIMED_OUT;
    }
    return 0;
}

static void write_interrupt_error(int code, char * error, size_t error_size) {
    write_error(
        error,
        error_size,
        code == BILING_LLAMA_TIMED_OUT ? "Scoring timed out." : "Scoring was cancelled."
    );
}

// Installed via llama_set_abort_callback: called between graph nodes during
// llama_decode, so a cancel or an expired deadline aborts the decode within
// milliseconds instead of after the full batch.
static bool should_abort(void * data) {
    return interrupt_code((struct BiLingLlama *) data) != 0;
}

static int tokenize(
    const struct llama_vocab * vocab,
    const char * text,
    bool add_special,
    llama_token ** output
) {
    const int text_length = (int) strlen(text);
    int capacity = text_length + 8;
    if (capacity < 32) {
        capacity = 32;
    }
    llama_token * tokens = (llama_token *) malloc(sizeof(llama_token) * (size_t) capacity);
    if (tokens == NULL) {
        return -1;
    }
    int count = llama_tokenize(vocab, text, text_length, tokens, capacity, add_special, false);
    if (count < 0) {
        capacity = -count;
        llama_token * resized = (llama_token *) realloc(tokens, sizeof(llama_token) * (size_t) capacity);
        if (resized == NULL) {
            free(tokens);
            return -1;
        }
        tokens = resized;
        count = llama_tokenize(vocab, text, text_length, tokens, capacity, add_special, false);
    }
    if (count < 0) {
        free(tokens);
        return -1;
    }
    *output = tokens;
    return count;
}

// log(sum(exp(row))) over the full vocabulary, vectorized with Accelerate.
// The scalar version of this loop dominated per-keystroke CPU time.
static double row_logsumexp(const float * row, int count, float * scratch) {
    float max_value = -INFINITY;
    vDSP_maxv(row, 1, &max_value, (vDSP_Length) count);
    if (!isfinite(max_value)) {
        return (double) max_value;
    }
    const float negative_max = -max_value;
    vDSP_vsadd(row, 1, &negative_max, scratch, 1, (vDSP_Length) count);
    vvexpf(scratch, scratch, &count);
    float sum = 0.0f;
    vDSP_sve(scratch, 1, &sum, (vDSP_Length) count);
    return (double) max_value + log((double) sum);
}

static void invalidate_cache(struct BiLingLlama * instance) {
    instance->cache_valid = false;
    instance->cached_count = 0;
    llama_memory_clear(llama_get_memory(instance->context), false);
}

static void clear_candidate_sequences(struct BiLingLlama * instance) {
    llama_memory_t memory = llama_get_memory(instance->context);
    for (llama_seq_id seq = 1; seq < BILING_MAX_SEQUENCES; seq++) {
        llama_memory_seq_rm(memory, seq, -1, -1);
    }
}

static bool store_cached_tokens(struct BiLingLlama * instance, const llama_token * tokens, int count) {
    if (count > instance->cached_capacity) {
        llama_token * grown = (llama_token *) realloc(
            instance->cached_tokens,
            sizeof(llama_token) * (size_t) count
        );
        if (grown == NULL) {
            return false;
        }
        instance->cached_tokens = grown;
        instance->cached_capacity = count;
    }
    memcpy(instance->cached_tokens, tokens, sizeof(llama_token) * (size_t) count);
    instance->cached_count = count;
    return true;
}

BiLingLlama * biling_llama_open(
    const char * model_path,
    const char * adapter_path,
    float adapter_scale,
    char * error,
    size_t error_size
) {
    if (model_path == NULL || model_path[0] == '\0') {
        write_error(error, error_size, "No model path was provided.");
        return NULL;
    }
    llama_backend_init();
    struct llama_model_params model_params = llama_model_default_params();
    model_params.n_gpu_layers = -1;
    model_params.use_mmap = true;
    model_params.use_mlock = false;

    // The GGUF is untrusted input (users can point BILING_MODEL_PATH anywhere).
    // llama.cpp validates the magic/metadata and returns NULL on anything it
    // rejects; treat every NULL and every implausible vocab as a load failure
    // rather than limping on.
    struct llama_model * model = llama_model_load_from_file(model_path, model_params);
    if (model == NULL) {
        write_error(error, error_size, "llama.cpp could not load the GGUF model (missing, corrupt, or out of memory).");
        return NULL;
    }
    const struct llama_vocab * vocab = llama_model_get_vocab(model);
    if (vocab == NULL || llama_vocab_n_tokens(vocab) < 1) {
        llama_model_free(model);
        write_error(error, error_size, "The GGUF model has no usable vocabulary.");
        return NULL;
    }

    struct llama_context_params context_params = llama_context_default_params();
    context_params.n_ctx = 1536;
    context_params.n_batch = 1536;
    context_params.n_ubatch = 512;
    context_params.n_seq_max = BILING_MAX_SEQUENCES;
    context_params.n_threads = 6;
    context_params.n_threads_batch = 8;
    context_params.embeddings = false;
    context_params.offload_kqv = true;
    context_params.kv_unified = true;

    struct llama_context * context = llama_init_from_model(model, context_params);
    if (context == NULL) {
        llama_model_free(model);
        write_error(error, error_size, "llama.cpp could not create an inference context.");
        return NULL;
    }

    struct BiLingLlama * instance = (struct BiLingLlama *) calloc(1, sizeof(struct BiLingLlama));
    if (instance == NULL) {
        llama_free(context);
        llama_model_free(model);
        write_error(error, error_size, "Out of memory while initializing Qwen.");
        return NULL;
    }
    instance->model = model;
    instance->context = context;
    instance->vocab = vocab;
    atomic_store(&instance->cancelled, false);
    atomic_store(&instance->deadline_ns, 0);
    llama_set_abort_callback(context, should_abort, instance);

    const int vocabulary_size = llama_vocab_n_tokens(instance->vocab);
    instance->cached_logits = (float *) malloc(sizeof(float) * (size_t) vocabulary_size);
    instance->scratch = (float *) malloc(sizeof(float) * (size_t) vocabulary_size);
    if (instance->cached_logits == NULL || instance->scratch == NULL) {
        biling_llama_close(instance);
        write_error(error, error_size, "Out of memory while initializing Qwen buffers.");
        return NULL;
    }

    // A personal LoRA adapter is optional and must never take typing down:
    // if it fails to load, continue with the plain base model and say so.
    const char * adapter_note = "";
    if (adapter_path != NULL && adapter_path[0] != '\0') {
        instance->adapter = llama_adapter_lora_init(model, adapter_path);
        if (instance->adapter != NULL) {
            float scale = adapter_scale > 0.0f ? adapter_scale : 1.0f;
            if (llama_set_adapters_lora(context, &instance->adapter, 1, &scale) == 0) {
                adapter_note = " · LoRA";
            } else {
                llama_adapter_lora_free(instance->adapter);
                instance->adapter = NULL;
                adapter_note = " · LoRA 未生效";
            }
        } else {
            adapter_note = " · LoRA 加载失败";
        }
    }

    char model_description[160] = {0};
    llama_model_desc(model, model_description, sizeof(model_description));
    snprintf(
        instance->description,
        sizeof(instance->description),
        "%s · %.0f MB · %d tokens%s",
        model_description,
        (double) llama_model_size(model) / 1024.0 / 1024.0,
        llama_vocab_n_tokens(instance->vocab),
        adapter_note
    );
    return instance;
}

void biling_llama_close(BiLingLlama * instance) {
    if (instance == NULL) {
        return;
    }
    free(instance->cached_tokens);
    free(instance->cached_logits);
    free(instance->scratch);
    if (instance->adapter != NULL) {
        llama_adapter_lora_free(instance->adapter);
    }
    llama_free(instance->context);
    llama_model_free(instance->model);
    free(instance);
}

// Ensures sequence 0 holds exactly `count` context tokens and that
// instance->cached_logits/cached_logsumexp describe the next-token
// distribution after them. Decodes only the divergent suffix.
static int refresh_context(
    struct BiLingLlama * instance,
    const llama_token * tokens,
    int count,
    char * error,
    size_t error_size
) {
    llama_memory_t memory = llama_get_memory(instance->context);

    int lcp = 0;
    if (instance->cache_valid) {
        const int comparable = instance->cached_count < count ? instance->cached_count : count;
        while (lcp < comparable && instance->cached_tokens[lcp] == tokens[lcp]) {
            lcp++;
        }
        if (lcp == count && lcp == instance->cached_count) {
            return 0; // Unchanged context: reuse cached KV and logits.
        }
    }

    // Drop stale KV cells past the shared prefix. When the new context is a
    // pure prefix of the cached one, re-decode its final token so fresh logits
    // exist for that position.
    int decode_from = lcp;
    if (decode_from >= count) {
        decode_from = count - 1;
    }
    llama_memory_seq_rm(memory, 0, decode_from, -1);

    const int suffix_count = count - decode_from;
    struct llama_batch batch = llama_batch_init(suffix_count, 0, 1);
    for (int index = 0; index < suffix_count; index++) {
        batch.token[index] = tokens[decode_from + index];
        batch.pos[index] = decode_from + index;
        batch.n_seq_id[index] = 1;
        batch.seq_id[index][0] = 0;
        batch.logits[index] = (int8_t) (index == suffix_count - 1);
    }
    batch.n_tokens = suffix_count;
    const int decode_result = llama_decode(instance->context, batch);
    llama_batch_free(batch);
    if (decode_result != 0) {
        // An aborted decode leaves partially processed ubatches in memory, so
        // the cache must be rebuilt from scratch either way.
        invalidate_cache(instance);
        if (decode_result == 2) {
            const int code = interrupt_code(instance);
            const int mapped = code != 0 ? code : BILING_LLAMA_CANCELLED;
            write_interrupt_error(mapped, error, error_size);
            return mapped;
        }
        write_error(error, error_size, "Qwen decode failed.");
        return -4;
    }

    const float * logits = llama_get_logits_ith(instance->context, -1);
    if (logits == NULL) {
        invalidate_cache(instance);
        write_error(error, error_size, "Qwen returned no logits.");
        return -5;
    }
    const int vocabulary_size = llama_vocab_n_tokens(instance->vocab);
    memcpy(instance->cached_logits, logits, sizeof(float) * (size_t) vocabulary_size);
    instance->cached_logsumexp = row_logsumexp(instance->cached_logits, vocabulary_size, instance->scratch);
    if (!store_cached_tokens(instance, tokens, count)) {
        invalidate_cache(instance);
        write_error(error, error_size, "Out of memory while caching the context.");
        return -6;
    }
    instance->cache_valid = true;
    return 0;
}

// Per-candidate scoring plan, derived from the merged (context + candidate)
// tokenization. Token boundaries can merge across the join, so the candidate
// is never tokenized on its own: the merged tokens are compared against the
// context tokens and only the divergent suffix is scored.
struct CandidatePlan {
    llama_token * owned;        // full merged tokenization (owner for free())
    const llama_token * tokens; // kept view (owned + drop_front)
    int count;                  // kept merged token count
    int feed_from;              // first kept token index fed to the model
    int feed_count;             // fed tokens (through the penultimate one)
    int scored_count;           // suffix tokens whose log-prob is accumulated
    int wave_row;               // this candidate's first row in the current wave batch
};

static int score_with_deadline(
    struct BiLingLlama * instance,
    const char * context,
    const char * const * candidates,
    int candidate_count,
    float * scores,
    char * error,
    size_t error_size
) {
    int early = interrupt_code(instance);
    if (early != 0) {
        write_interrupt_error(early, error, error_size);
        return early;
    }

    llama_memory_t memory = llama_get_memory(instance->context);
    // Candidate sequences from any previous request (including error exits)
    // must not survive into this one; sequence 0 is the only persistent state.
    clear_candidate_sequences(instance);

    const char * prompt = context == NULL || context[0] == '\0' ? "。" : context;
    llama_token * context_full = NULL;
    const int context_full_count = tokenize(instance->vocab, prompt, true, &context_full);
    if (context_full_count < 1) {
        write_error(error, error_size, "Could not tokenize the committed context.");
        return -3;
    }
    // Token-level trim with hysteresis. drop_front is also applied to every
    // merged tokenization below so context and merged token indices stay
    // aligned; BPE divergence is local to the join, far past drop_front.
    const int drop_front = context_full_count > BILING_CONTEXT_LIMIT
        ? context_full_count - BILING_CONTEXT_KEEP
        : 0;
    const llama_token * context_tokens = context_full + drop_front;
    const int context_count = context_full_count - drop_front;

    int result = refresh_context(instance, context_tokens, context_count, error, error_size);
    if (result != 0) {
        free(context_full);
        return result;
    }

    const int vocabulary_size = llama_vocab_n_tokens(instance->vocab);
    const float * context_logits = instance->cached_logits;
    const double context_logsumexp = instance->cached_logsumexp;
    const int n_ctx = (int) llama_n_ctx(instance->context);
    const int n_batch = (int) llama_n_batch(instance->context);
    // With a unified KV cache, context cells plus every candidate row decoded
    // in one wave must fit in n_ctx together.
    int wave_capacity = n_ctx - context_count;
    if (wave_capacity > n_batch) {
        wave_capacity = n_batch;
    }
    if (wave_capacity < 1) {
        free(context_full);
        write_error(error, error_size, "The context leaves no room for candidate scoring.");
        return -7;
    }

    struct CandidatePlan * plans =
        (struct CandidatePlan *) calloc((size_t) candidate_count, sizeof(struct CandidatePlan));
    const size_t prompt_length = strlen(prompt);
    char * merged_text = NULL;
    size_t merged_capacity = 0;
    if (plans == NULL) {
        free(context_full);
        write_error(error, error_size, "Out of memory while planning candidates.");
        return -6;
    }

    // Plan every candidate: tokenize (context + candidate) as one string,
    // find the longest common token prefix with the context tokenization, and
    // mark the remainder for scoring.
    for (int index = 0; index < candidate_count; index++) {
        struct CandidatePlan * plan = &plans[index];
        scores[index] = -INFINITY;
        const char * candidate = candidates[index];
        if (candidate == NULL || candidate[0] == '\0') {
            continue;
        }
        const size_t candidate_length = strlen(candidate);
        const size_t needed = prompt_length + candidate_length + 1;
        if (needed > merged_capacity) {
            char * grown = (char *) realloc(merged_text, needed);
            if (grown == NULL) {
                result = -6;
                write_error(error, error_size, "Out of memory while merging candidate text.");
                break;
            }
            merged_text = grown;
            merged_capacity = needed;
        }
        memcpy(merged_text, prompt, prompt_length);
        memcpy(merged_text + prompt_length, candidate, candidate_length + 1);

        llama_token * merged_full = NULL;
        const int merged_full_count = tokenize(instance->vocab, merged_text, true, &merged_full);
        if (merged_full_count < 1 || merged_full_count - drop_front < 1) {
            free(merged_full);
            continue;
        }
        const llama_token * merged = merged_full + drop_front;
        const int merged_count = merged_full_count - drop_front;

        int lcp = 0;
        const int comparable = context_count < merged_count ? context_count : merged_count;
        while (lcp < comparable && context_tokens[lcp] == merged[lcp]) {
            lcp++;
        }
        if (lcp >= merged_count) {
            // The merged string adds no tokens beyond the context prefix
            // (empty or fully absorbed candidate): nothing scoreable.
            free(merged_full);
            continue;
        }

        int feed_from;
        if (lcp == context_count) {
            // No boundary merge: the whole context KV is reusable and the
            // first suffix token is priced from the cached context logits.
            scores[index] = (float) ((double) context_logits[merged[lcp]] - context_logsumexp);
            plan->scored_count = merged_count - lcp;
            feed_from = lcp;
        } else {
            // The join merged into the context's tail: roll back to the common
            // prefix and re-decode from one token before the divergence so the
            // first divergent token gets a real conditional probability.
            // (lcp == 0 would need P(first token) from a model with no BOS;
            // that token is skipped — unreachable with the sentinel context.)
            const int score_from = lcp > 0 ? lcp : 1;
            plan->scored_count = merged_count - score_from;
            if (plan->scored_count < 1) {
                free(merged_full);
                continue;
            }
            scores[index] = 0.0f;
            feed_from = score_from - 1;
        }
        const int feed_count = (merged_count - 1) - feed_from;
        if (feed_count > wave_capacity) {
            // Cannot fit this candidate's continuation in the KV window.
            scores[index] = -INFINITY;
            free(merged_full);
            plan->scored_count = 0;
            continue;
        }
        plan->owned = merged_full;
        plan->tokens = merged;
        plan->count = merged_count;
        plan->feed_from = feed_from;
        plan->feed_count = feed_count;
    }

    // Decode the planned continuations in waves that respect the KV window,
    // harvesting logits after each wave (llama.cpp reuses the logits buffer on
    // the next decode). Cancellation and the deadline are re-checked between
    // waves and between candidates, not just inside llama_decode.
    int index = 0;
    while (result == 0 && index < candidate_count) {
        const int wave_start = index;
        int wave_rows = 0;
        while (index < candidate_count) {
            const int rows = plans[index].feed_count;
            if (plans[index].owned == NULL || rows == 0) {
                index++;
                continue;
            }
            if (wave_rows > 0 && wave_rows + rows > wave_capacity) {
                break;
            }
            plans[index].wave_row = wave_rows;
            wave_rows += rows;
            index++;
        }
        if (wave_rows == 0) {
            continue;
        }
        result = interrupt_code(instance);
        if (result != 0) {
            write_interrupt_error(result, error, error_size);
            break;
        }

        struct llama_batch wave = llama_batch_init(wave_rows, 0, 1);
        int batch_index = 0;
        for (int c = wave_start; c < index; c++) {
            const struct CandidatePlan * plan = &plans[c];
            if (plan->owned == NULL || plan->feed_count == 0) {
                continue;
            }
            const llama_seq_id seq = (llama_seq_id) (c + 1);
            if (plan->feed_from > 0) {
                // Share the common-prefix KV cells instead of re-decoding them.
                llama_memory_seq_cp(memory, 0, seq, 0, plan->feed_from);
            }
            for (int t = 0; t < plan->feed_count; t++) {
                wave.token[batch_index] = plan->tokens[plan->feed_from + t];
                wave.pos[batch_index] = plan->feed_from + t;
                wave.n_seq_id[batch_index] = 1;
                wave.seq_id[batch_index][0] = seq;
                wave.logits[batch_index] = 1;
                batch_index++;
            }
        }
        wave.n_tokens = batch_index;
        const int decode_result = llama_decode(instance->context, wave);
        llama_batch_free(wave);
        if (decode_result != 0) {
            if (decode_result == 2) {
                const int code = interrupt_code(instance);
                result = code != 0 ? code : BILING_LLAMA_CANCELLED;
                write_interrupt_error(result, error, error_size);
                // Sequence 0 was not part of this batch; only candidate
                // sequences hold partial state and are cleared below.
            } else {
                invalidate_cache(instance);
                write_error(error, error_size, "Qwen continuation decode failed.");
                result = -7;
            }
            break;
        }

        for (int c = wave_start; c < index && result == 0; c++) {
            const struct CandidatePlan * plan = &plans[c];
            if (plan->owned == NULL || plan->feed_count == 0) {
                continue;
            }
            result = interrupt_code(instance);
            if (result != 0) {
                write_interrupt_error(result, error, error_size);
                break;
            }
            for (int r = 0; r < plan->feed_count; r++) {
                const float * row = llama_get_logits_ith(instance->context, plan->wave_row + r);
                if (row == NULL) {
                    scores[c] = -INFINITY;
                    break;
                }
                const llama_token target = plan->tokens[plan->feed_from + r + 1];
                const double row_logsum = row_logsumexp(row, vocabulary_size, instance->scratch);
                scores[c] += (float) ((double) row[target] - row_logsum);
            }
        }
        for (int c = wave_start; c < index; c++) {
            if (plans[c].owned != NULL && plans[c].feed_count > 0) {
                llama_memory_seq_rm(memory, (llama_seq_id) (c + 1), -1, -1);
            }
        }
    }

    if (result == 0) {
        // Normalize gently for BPE fragmentation while keeping multi-token
        // errors costly. The divisor is the number of merged suffix tokens
        // actually scored, which equals the candidate's own token count
        // whenever no boundary merge occurred.
        for (int c = 0; c < candidate_count; c++) {
            if (plans[c].scored_count > 1 && isfinite(scores[c])) {
                scores[c] /= sqrtf((float) plans[c].scored_count);
            }
        }
    }

    // An aborted wave may leave partial candidate cells behind; drop them so
    // only sequence 0 persists regardless of how this call ended.
    clear_candidate_sequences(instance);
    for (int c = 0; c < candidate_count; c++) {
        free(plans[c].owned);
    }
    free(plans);
    free(merged_text);
    free(context_full);
    return result;
}

int biling_llama_score(
    BiLingLlama * instance,
    const char * context,
    const char * const * candidates,
    int candidate_count,
    long timeout_ms,
    float * scores,
    char * error,
    size_t error_size
) {
    if (instance == NULL || candidates == NULL || scores == NULL
        || candidate_count < 1 || candidate_count > BILING_MAX_SEQUENCES - 1) {
        write_error(error, error_size, "Invalid scoring request.");
        return -1;
    }
    const uint64_t deadline = timeout_ms > 0
        ? monotonic_ns() + (uint64_t) timeout_ms * 1000000ull
        : 0;
    atomic_store(&instance->deadline_ns, deadline);
    const int result = score_with_deadline(
        instance, context, candidates, candidate_count, scores, error, error_size
    );
    atomic_store(&instance->deadline_ns, 0);
    return result;
}

void biling_llama_cancel(BiLingLlama * instance) {
    if (instance != NULL) {
        atomic_store(&instance->cancelled, true);
    }
}

void biling_llama_reset_cancel(BiLingLlama * instance) {
    if (instance != NULL) {
        atomic_store(&instance->cancelled, false);
    }
}

const char * biling_llama_description(BiLingLlama * instance) {
    return instance == NULL ? "Qwen unavailable" : instance->description;
}

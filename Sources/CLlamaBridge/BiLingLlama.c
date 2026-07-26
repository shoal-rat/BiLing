#include "BiLingLlama.h"

#include <Accelerate/Accelerate.h>
#include <llama.h>
#include <math.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// The committed context is re-sent on every keystroke, but between keystrokes it
// is either identical or extended. Sequence 0 keeps the context's KV cells alive
// across requests, so only new suffix tokens are ever decoded. The context is
// trimmed with hysteresis (drop to KEEP once it exceeds LIMIT) so the retained
// prefix stays byte-stable between trims and the cache keeps hitting.
#define BILING_CONTEXT_LIMIT 1300
#define BILING_CONTEXT_KEEP 900

struct BiLingLlama {
    struct llama_model * model;
    struct llama_context * context;
    const struct llama_vocab * vocab;
    volatile bool cancelled;
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

static bool should_abort(void * data) {
    const struct BiLingLlama * instance = (const struct BiLingLlama *) data;
    return instance->cancelled;
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

BiLingLlama * biling_llama_open(const char * model_path, char * error, size_t error_size) {
    if (model_path == NULL || model_path[0] == '\0') {
        write_error(error, error_size, "No model path was provided.");
        return NULL;
    }
    llama_backend_init();
    struct llama_model_params model_params = llama_model_default_params();
    model_params.n_gpu_layers = -1;
    model_params.use_mmap = true;
    model_params.use_mlock = false;

    struct llama_model * model = llama_model_load_from_file(model_path, model_params);
    if (model == NULL) {
        write_error(error, error_size, "llama.cpp could not load the bundled GGUF model.");
        return NULL;
    }

    struct llama_context_params context_params = llama_context_default_params();
    context_params.n_ctx = 1536;
    context_params.n_batch = 1536;
    context_params.n_ubatch = 512;
    context_params.n_seq_max = 48;
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
    instance->vocab = llama_model_get_vocab(model);
    instance->cancelled = false;
    llama_set_abort_callback(context, should_abort, instance);

    const int vocabulary_size = llama_vocab_n_tokens(instance->vocab);
    instance->cached_logits = (float *) malloc(sizeof(float) * (size_t) vocabulary_size);
    instance->scratch = (float *) malloc(sizeof(float) * (size_t) vocabulary_size);
    if (instance->cached_logits == NULL || instance->scratch == NULL) {
        biling_llama_close(instance);
        write_error(error, error_size, "Out of memory while initializing Qwen buffers.");
        return NULL;
    }

    char model_description[160] = {0};
    llama_model_desc(model, model_description, sizeof(model_description));
    snprintf(
        instance->description,
        sizeof(instance->description),
        "%s · %.0f MB · %d tokens",
        model_description,
        (double) llama_model_size(model) / 1024.0 / 1024.0,
        llama_vocab_n_tokens(instance->vocab)
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
        invalidate_cache(instance);
        write_error(error, error_size, decode_result == 2 ? "Scoring was cancelled." : "Qwen decode failed.");
        return decode_result == 2 ? -2 : -4;
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

int biling_llama_score(
    BiLingLlama * instance,
    const char * context,
    const char * const * candidates,
    int candidate_count,
    float * scores,
    char * error,
    size_t error_size
) {
    if (instance == NULL || candidates == NULL || scores == NULL || candidate_count < 1) {
        write_error(error, error_size, "Invalid scoring request.");
        return -1;
    }
    if (instance->cancelled) {
        write_error(error, error_size, "Scoring was cancelled.");
        return -2;
    }

    llama_memory_t memory = llama_get_memory(instance->context);
    // Candidate sequences from any previous request (including error exits)
    // must not survive into this one; sequence 0 is the only persistent state.
    for (llama_seq_id seq = 1; seq < 48; seq++) {
        llama_memory_seq_rm(memory, seq, -1, -1);
    }

    const char * prompt = context == NULL || context[0] == '\0' ? "。" : context;
    llama_token * context_tokens = NULL;
    int context_count = tokenize(instance->vocab, prompt, true, &context_tokens);
    if (context_count < 1) {
        write_error(error, error_size, "Could not tokenize the committed context.");
        return -3;
    }
    if (context_count > BILING_CONTEXT_LIMIT) {
        const int keep = BILING_CONTEXT_KEEP;
        memmove(
            context_tokens,
            context_tokens + (context_count - keep),
            sizeof(llama_token) * (size_t) keep
        );
        context_count = keep;
    }

    const int context_result = refresh_context(instance, context_tokens, context_count, error, error_size);
    free(context_tokens);
    if (context_result != 0) {
        return context_result;
    }

    const int vocabulary_size = llama_vocab_n_tokens(instance->vocab);
    const float * context_logits = instance->cached_logits;
    const double context_logsumexp = instance->cached_logsumexp;

    llama_token ** candidate_tokens = (llama_token **) calloc((size_t) candidate_count, sizeof(llama_token *));
    int * candidate_lengths = (int *) calloc((size_t) candidate_count, sizeof(int));
    int * batch_offsets = (int *) calloc((size_t) candidate_count, sizeof(int));
    if (candidate_tokens == NULL || candidate_lengths == NULL || batch_offsets == NULL) {
        free(candidate_tokens);
        free(candidate_lengths);
        free(batch_offsets);
        write_error(error, error_size, "Out of memory while tokenizing candidates.");
        return -6;
    }

    int total_continuation_tokens = 0;
    for (int index = 0; index < candidate_count; index++) {
        candidate_lengths[index] = tokenize(
            instance->vocab,
            candidates[index],
            false,
            &candidate_tokens[index]
        );
        if (candidate_lengths[index] < 1) {
            scores[index] = -INFINITY;
        } else {
            scores[index] = (float) ((double) context_logits[candidate_tokens[index][0]] - context_logsumexp);
            total_continuation_tokens += candidate_lengths[index] - 1;
        }
    }

    int result = 0;
    if (total_continuation_tokens > 0) {
        for (int index = 0; index < candidate_count; index++) {
            if (candidate_lengths[index] > 1) {
                llama_memory_seq_cp(memory, 0, index + 1, 0, -1);
            }
        }

        struct llama_batch continuation = llama_batch_init(total_continuation_tokens, 0, 1);
        int batch_index = 0;
        for (int index = 0; index < candidate_count; index++) {
            batch_offsets[index] = batch_index;
            // Decode through the penultimate token. Each output row scores the next token.
            for (int token_index = 0; token_index < candidate_lengths[index] - 1; token_index++) {
                continuation.token[batch_index] = candidate_tokens[index][token_index];
                continuation.pos[batch_index] = context_count + token_index;
                continuation.n_seq_id[batch_index] = 1;
                continuation.seq_id[batch_index][0] = index + 1;
                continuation.logits[batch_index] = 1;
                batch_index++;
            }
        }
        continuation.n_tokens = batch_index;
        const int decode_result = llama_decode(instance->context, continuation);
        llama_batch_free(continuation);
        if (decode_result != 0) {
            invalidate_cache(instance);
            write_error(error, error_size, decode_result == 2 ? "Scoring was cancelled." : "Qwen continuation decode failed.");
            result = decode_result == 2 ? -2 : -7;
        } else {
            for (int index = 0; index < candidate_count; index++) {
                const int length = candidate_lengths[index];
                for (int token_index = 1; token_index < length; token_index++) {
                    const int row_index = batch_offsets[index] + token_index - 1;
                    const float * row = llama_get_logits_ith(instance->context, row_index);
                    if (row == NULL) {
                        scores[index] = -INFINITY;
                        break;
                    }
                    const double row_logsum = row_logsumexp(row, vocabulary_size, instance->scratch);
                    scores[index] += (float) ((double) row[candidate_tokens[index][token_index]] - row_logsum);
                }
                // Normalize gently for BPE fragmentation while keeping multi-token errors costly.
                if (length > 1 && isfinite(scores[index])) {
                    scores[index] /= sqrtf((float) length);
                }
            }
            for (int index = 0; index < candidate_count; index++) {
                if (candidate_lengths[index] > 1) {
                    llama_memory_seq_rm(memory, index + 1, -1, -1);
                }
            }
        }
    }

    for (int index = 0; index < candidate_count; index++) {
        free(candidate_tokens[index]);
    }
    free(candidate_tokens);
    free(candidate_lengths);
    free(batch_offsets);
    return result;
}

void biling_llama_cancel(BiLingLlama * instance) {
    if (instance != NULL) {
        instance->cancelled = true;
    }
}

void biling_llama_reset_cancel(BiLingLlama * instance) {
    if (instance != NULL) {
        instance->cancelled = false;
    }
}

const char * biling_llama_description(BiLingLlama * instance) {
    return instance == NULL ? "Qwen unavailable" : instance->description;
}

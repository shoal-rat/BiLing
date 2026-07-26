#include "BiLingLlama.h"

#include <llama.h>
#include <math.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct BiLingLlama {
    struct llama_model * model;
    struct llama_context * context;
    const struct llama_vocab * vocab;
    volatile bool cancelled;
    char description[256];
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
    llama_free(instance->context);
    llama_model_free(instance->model);
    free(instance);
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

    const char * prompt = context == NULL || context[0] == '\0' ? "。" : context;
    llama_token * context_tokens = NULL;
    int context_count = tokenize(instance->vocab, prompt, true, &context_tokens);
    if (context_count < 1) {
        write_error(error, error_size, "Could not tokenize the committed context.");
        return -3;
    }
    if (context_count > 900) {
        const int keep = 900;
        memmove(context_tokens, context_tokens + (context_count - keep), sizeof(llama_token) * (size_t) keep);
        context_count = keep;
    }

    llama_memory_clear(llama_get_memory(instance->context), true);
    struct llama_batch batch = llama_batch_get_one(context_tokens, context_count);
    int decode_result = llama_decode(instance->context, batch);
    free(context_tokens);
    if (decode_result != 0) {
        write_error(error, error_size, decode_result == 2 ? "Scoring was cancelled." : "Qwen decode failed.");
        return decode_result == 2 ? -2 : -4;
    }

    float * context_logits = llama_get_logits_ith(instance->context, -1);
    if (context_logits == NULL) {
        write_error(error, error_size, "Qwen returned no logits.");
        return -5;
    }

    const int vocabulary_size = llama_vocab_n_tokens(instance->vocab);
    float context_max = -INFINITY;
    for (int token = 0; token < vocabulary_size; token++) {
        if (context_logits[token] > context_max) {
            context_max = context_logits[token];
        }
    }
    double context_sum = 0.0;
    for (int token = 0; token < vocabulary_size; token++) {
        context_sum += exp((double) context_logits[token] - context_max);
    }
    const double context_logsumexp = context_max + log(context_sum);

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

    if (total_continuation_tokens > 0) {
        llama_memory_t memory = llama_get_memory(instance->context);
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
        decode_result = llama_decode(instance->context, continuation);
        if (decode_result != 0) {
            llama_batch_free(continuation);
            for (int index = 0; index < candidate_count; index++) {
                free(candidate_tokens[index]);
            }
            free(candidate_tokens);
            free(candidate_lengths);
            free(batch_offsets);
            write_error(error, error_size, decode_result == 2 ? "Scoring was cancelled." : "Qwen continuation decode failed.");
            return decode_result == 2 ? -2 : -7;
        }

        for (int index = 0; index < candidate_count; index++) {
            const int length = candidate_lengths[index];
            for (int token_index = 1; token_index < length; token_index++) {
                const int row_index = batch_offsets[index] + token_index - 1;
                float * row = llama_get_logits_ith(instance->context, row_index);
                if (row == NULL) {
                    scores[index] = -INFINITY;
                    break;
                }
                float row_max = -INFINITY;
                for (int token = 0; token < vocabulary_size; token++) {
                    if (row[token] > row_max) {
                        row_max = row[token];
                    }
                }
                double row_sum = 0.0;
                for (int token = 0; token < vocabulary_size; token++) {
                    row_sum += exp((double) row[token] - row_max);
                }
                const double row_logsumexp = row_max + log(row_sum);
                scores[index] += (float) ((double) row[candidate_tokens[index][token_index]] - row_logsumexp);
            }
            // Normalize gently for BPE fragmentation while keeping multi-token errors costly.
            if (length > 1 && isfinite(scores[index])) {
                scores[index] /= sqrtf((float) length);
            }
        }
        llama_batch_free(continuation);
    }

    for (int index = 0; index < candidate_count; index++) {
        free(candidate_tokens[index]);
    }
    free(candidate_tokens);
    free(candidate_lengths);
    free(batch_offsets);
    return 0;
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

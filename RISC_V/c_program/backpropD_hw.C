#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>

// ──────────────────────────────────────────────────────────────────────────
//  HARDWARE-MATCHED PARAMETERS
//  These MUST match the neuron_accelerator hardware configuration:
//    Decay   = LIF24 mode → β = 0.75 → V_decay = (V>>1) + (V>>2)
//    Reset   = RESET_ZERO → membrane set to 0 after spike
//    Spike   = V > threshold  (strictly greater, matching hardware)
//    Weights = Q4.28 in hardware → scale = 256 here, max float = 7.999
//
//  HARDWARE-SAFE WEIGHT CLAMPS  (Q4.28 = 28 fractional bits, max 7.999 float)
//    W1: up to ~100 inputs active simultaneously → max W1 float = 7.999/100 = 0.08
//        → int clamp = 0.08 × 256 ≈ 20
//    W2: up to 200 hidden neurons, but 200 × 0.04 _float_ × any spike fraction
//        In practice spike rate ~5-10%, so ≤20 simultaneous.
//        max W2 float = 7.999/20 = 0.40 → int clamp = 100 (conservative)
//
//  FLOAT SHADOW WEIGHTS + FLOAT BACKWARD
//    Pure integer backward with SCALE=256 and small weights silently truncates
//    gradients to 0: (6 × 10 / 256) >> 8 = 0 → the network never learns.
//    Solution: float shadow weights W1f/W2f accumulate real gradient steps;
//    int16 W1/W2 are re-derived from them each update (fixed-point QAT style).
// ──────────────────────────────────────────────────────────────────────────
#define TIMESTEPS    16
#define INPUT_SIZE   784
#define HIDDEN_SIZE  200
#define OUTPUT_SIZE  10
#define SCALE        256
#define THRESHOLD    (1 * SCALE)   /* 1.0 in fixed-point */
#define BETA         192           /* 0.75 × 256 = 192  → matches LIF24 hardware mode */

/* Hardware-safe weight clamps */
#define W1_CLAMP     20            /* max int = 20/256 = 0.078 float */
#define W2_CLAMP     100           /* max int = 100/256 = 0.391 float */

/* Training hyperparameters */
#define EPOCHS       5
#define BATCH_SIZE   32
#define LR_F         0.005f

/* Float shadow weights — accumulate real-valued gradient steps */
float   W1f[INPUT_SIZE][HIDDEN_SIZE];
float   W2f[HIDDEN_SIZE][OUTPUT_SIZE];
/* Quantised weights for integer forward pass */
int16_t W1[INPUT_SIZE][HIDDEN_SIZE];
int16_t W2[HIDDEN_SIZE][OUTPUT_SIZE];

uint8_t input_spikes_hist[TIMESTEPS][INPUT_SIZE];
uint8_t spikes1_hist[TIMESTEPS][HIDDEN_SIZE];
uint8_t spikes2_hist[TIMESTEPS][OUTPUT_SIZE];

/* Input neuron vmem history — all neurons are LIF including inputs.
 * The input current (raw pixel Poisson hit) drives mem0 through LIF dynamics.
 * Needed for surrogate gradient chain in BPTT through the input layer. */
int32_t mem0_hist[TIMESTEPS][INPUT_SIZE];

/* Hidden and output vmem history — captured BEFORE spike check and reset.
 * Used to dump actual LUT indices to compare with hardware. */
int32_t mem1_hist[TIMESTEPS][HIDDEN_SIZE];
int32_t mem2_hist[TIMESTEPS][OUTPUT_SIZE];

/* Float gradient accumulators — reset each batch */
float dW1_acc[INPUT_SIZE][HIDDEN_SIZE];
float dW2_acc[HIDDEN_SIZE][OUTPUT_SIZE];

float best_accuracy = 0.0f;

static void report_weight_saturation(const char *tag) {
    int w1_pos = 0, w1_neg = 0, w1_zero = 0;
    int w2_pos = 0, w2_neg = 0, w2_zero = 0;
    const int w1_total = INPUT_SIZE * HIDDEN_SIZE;
    const int w2_total = HIDDEN_SIZE * OUTPUT_SIZE;

    for (int i = 0; i < INPUT_SIZE; i++) {
        for (int j = 0; j < HIDDEN_SIZE; j++) {
            if (W1[i][j] == W1_CLAMP) w1_pos++;
            else if (W1[i][j] == -W1_CLAMP) w1_neg++;
            else if (W1[i][j] == 0) w1_zero++;
        }
    }
    for (int i = 0; i < HIDDEN_SIZE; i++) {
        for (int j = 0; j < OUTPUT_SIZE; j++) {
            if (W2[i][j] == W2_CLAMP) w2_pos++;
            else if (W2[i][j] == -W2_CLAMP) w2_neg++;
            else if (W2[i][j] == 0) w2_zero++;
        }
    }

    printf("[SAT] %s | W1 +clamp=%d (%.2f%%) -clamp=%d (%.2f%%) zero=%d (%.2f%%)\n",
           tag,
           w1_pos, 100.0f * (float)w1_pos / (float)w1_total,
           w1_neg, 100.0f * (float)w1_neg / (float)w1_total,
           w1_zero, 100.0f * (float)w1_zero / (float)w1_total);
    printf("[SAT] %s | W2 +clamp=%d (%.2f%%) -clamp=%d (%.2f%%) zero=%d (%.2f%%)\n",
           tag,
           w2_pos, 100.0f * (float)w2_pos / (float)w2_total,
           w2_neg, 100.0f * (float)w2_neg / (float)w2_total,
           w2_zero, 100.0f * (float)w2_zero / (float)w2_total);
}

/* ──────────────────────────────────────────────────────────────────────────
 * OPTIONAL DUMP OUTPUT (COMPILE WITH -DDUMP_VMEM_SPIKES)
 * ────────────────────────────────────────────────────────────────────────── */
#ifdef DUMP_VMEM_SPIKES
static FILE *dump_file = NULL;
static int sample_count = 0;

void dump_vmem_spikes_init() {
    dump_file = fopen("software_vmem_spikes.csv", "w");
    if (!dump_file) {
        fprintf(stderr, "Error: Could not open software_vmem_spikes.csv for writing\n");
        return;
    }
    /* Header: sample, ts, [784 input spikes], [200 h spikes], [10 o spikes], [200 h lut_idx], [10 o lut_idx] */
    fprintf(dump_file, "sample,ts");
    for (int i = 0; i < INPUT_SIZE; i++) fprintf(dump_file, ",inp_spk_%d", i);
    for (int i = 0; i < HIDDEN_SIZE; i++) fprintf(dump_file, ",h_spk_%d", i);
    for (int i = 0; i < OUTPUT_SIZE; i++) fprintf(dump_file, ",o_spk_%d", i);
    for (int i = 0; i < HIDDEN_SIZE; i++) fprintf(dump_file, ",h_lut_%d", i);
    for (int i = 0; i < OUTPUT_SIZE; i++) fprintf(dump_file, ",o_lut_%d", i);
    fprintf(dump_file, "\n");
    fflush(dump_file);
}

/* Convert int32 vmem (Q5.24 with SCALE=256) to 8-bit LUT index.
 * Hardware uses Q16.16, extracts bits[23:16].
 * Here: v_mem_float = mem / SCALE, clamp to [-128, 127], then map to [0, 255]. */
static inline uint8_t vmem_to_lut_index(int32_t mem) {
    float v = (float)mem / (float)SCALE;
    int32_t v_int = (int32_t)v;
    if (v_int > 127) v_int = 127;
    if (v_int < -128) v_int = -128;
    uint8_t idx = (uint8_t)(v_int + 128);
    return idx;
}

void dump_vmem_spikes_sample() {
    if (!dump_file) return;

    for (int t = 0; t < TIMESTEPS; t++) {
        fprintf(dump_file, "%d,%d", sample_count, t);

        /* Input spikes (784) */
        for (int i = 0; i < INPUT_SIZE; i++)
            fprintf(dump_file, ",%d", input_spikes_hist[t][i]);

        /* Hidden spikes (200) */
        for (int j = 0; j < HIDDEN_SIZE; j++)
            fprintf(dump_file, ",%d", spikes1_hist[t][j]);

        /* Output spikes (10) */
        for (int k = 0; k < OUTPUT_SIZE; k++)
            fprintf(dump_file, ",%d", spikes2_hist[t][k]);

        /* Hidden LUT indices (200) — convert saved vmem to LUT index */
        for (int j = 0; j < HIDDEN_SIZE; j++) {
            uint8_t idx = vmem_to_lut_index(mem1_hist[t][j]);
            fprintf(dump_file, ",%u", idx);
        }

        /* Output LUT indices (10) — convert saved vmem to LUT index */
        for (int k = 0; k < OUTPUT_SIZE; k++) {
            uint8_t idx = vmem_to_lut_index(mem2_hist[t][k]);
            fprintf(dump_file, ",%u", idx);
        }

        fprintf(dump_file, "\n");
    }
    fflush(dump_file);
    sample_count++;
}

void dump_vmem_spikes_close() {
    if (dump_file) {
        fclose(dump_file);
        printf(" >>> Dumped vmem/spikes to software_vmem_spikes.csv (%d samples) <<<\n", sample_count);
    }
}
#else
void dump_vmem_spikes_init() {}
void dump_vmem_spikes_sample() {}
void dump_vmem_spikes_close() {}
#endif

void save_weights_txt(const char* filename) {
    FILE *f = fopen(filename, "w");
    if (!f) { printf("Error: Could not open file for saving weights.\n"); return; }
    fprintf(f, "W1 Weights (%d x %d):\n", INPUT_SIZE, HIDDEN_SIZE);
    for (int i = 0; i < INPUT_SIZE; i++) {
        for (int j = 0; j < HIDDEN_SIZE; j++) fprintf(f, "%d ", W1[i][j]);
        fprintf(f, "\n");
    }
    fprintf(f, "\n-------------------------------------\n\n");
    fprintf(f, "W2 Weights (%d x %d):\n", HIDDEN_SIZE, OUTPUT_SIZE);
    for (int i = 0; i < HIDDEN_SIZE; i++) {
        for (int j = 0; j < OUTPUT_SIZE; j++) fprintf(f, "%d ", W2[i][j]);
        fprintf(f, "\n");
    }
    fclose(f);
    printf(" >>> Best weights saved to %s <<<\n", filename);
}

/* Float surrogate gradient — fast sigmoid: 1 / (1 + 4|v - v_t|)^2 */
static inline float surrogate_grad_f(int32_t mem_int)
{
    float v   = (float)mem_int / (float)SCALE;
    float vt  = (float)THRESHOLD / (float)SCALE;   /* = 1.0 */
    float den = 1.0f + 4.0f * fabsf(v - vt);
    return 1.0f / (den * den);
}

/* BACKWARD PASS — float arithmetic to prevent gradient truncation */
void backward_pass(uint8_t label, int32_t *output_rates_int) {
    /* MSE output error in float */
    float delta_out[OUTPUT_SIZE];
    for (int i = 0; i < OUTPUT_SIZE; i++) {
        float rate = (float)output_rates_int[i] / (float)SCALE;
        float y    = (i == (int)label) ? 1.0f : 0.0f;
        delta_out[i] = 2.0f * (rate - y);
    }

    float dm2[OUTPUT_SIZE] = {0};
    float dm1[HIDDEN_SIZE] = {0};
    float dm0[INPUT_SIZE]  = {0};   /* input layer temporal gradient (all neurons are LIF) */

    for (int t = TIMESTEPS - 1; t >= 0; t--) {
        float new_dm2[OUTPUT_SIZE] = {0};
        float new_dm1[HIDDEN_SIZE] = {0};
        float new_dm0[INPUT_SIZE]  = {0};

        /* Output layer */
        for (int k = 0; k < OUTPUT_SIZE; k++) {
            int32_t vmem_k = spikes2_hist[t][k] ? (THRESHOLD + 1) : 0;
            float sg = surrogate_grad_f(vmem_k);
            /* β=0.75 BPTT: decay term for membrane gradient */
            float d2 = (delta_out[k] + 0.75f * dm2[k]) * sg;

            for (int j = 0; j < HIDDEN_SIZE; j++)
                if (spikes1_hist[t][j])
                    dW2_acc[j][k] += d2;

            for (int j = 0; j < HIDDEN_SIZE; j++)
                new_dm1[j] += d2 * W2f[j][k];

            new_dm2[k] = d2 * (1.0f - (float)spikes2_hist[t][k]);
        }

        /* Hidden layer */
        for (int j = 0; j < HIDDEN_SIZE; j++) {
            int32_t vmem_j = spikes1_hist[t][j] ? (THRESHOLD + 1) : 0;
            float sg = surrogate_grad_f(vmem_j);
            float d1 = (new_dm1[j] + 0.75f * dm1[j]) * sg;

            for (int i = 0; i < INPUT_SIZE; i++)
                if (input_spikes_hist[t][i])
                    dW1_acc[i][j] += d1;

            /* Error propagated to input layer (for input LIF temporal gradient) */
            for (int i = 0; i < INPUT_SIZE; i++)
                new_dm0[i] += d1 * W1f[i][j];

            new_dm1[j] = d1 * (1.0f - (float)spikes1_hist[t][j]);
        }

        /* Input layer — all neurons are LIF, so BPTT temporal gradient applies.
         * No weights to update before input, but the temporal chain dm0 correctly
         * gates the surrogate gradient at the input membrane for dW1. */
        for (int i = 0; i < INPUT_SIZE; i++) {
            float sg0 = surrogate_grad_f(mem0_hist[t][i]);
            float d0 = (new_dm0[i] + 0.75f * dm0[i]) * sg0;
            new_dm0[i] = d0 * (1.0f - (float)input_spikes_hist[t][i]);
        }

        for (int k = 0; k < OUTPUT_SIZE; k++) dm2[k] = new_dm2[k];
        for (int j = 0; j < HIDDEN_SIZE; j++) dm1[j] = new_dm1[j];
        for (int i = 0; i < INPUT_SIZE; i++) dm0[i] = new_dm0[i];
    }
}

int train_on_sample_with_result(uint8_t label, uint8_t* pixels) {
    int32_t mem0[INPUT_SIZE]  = {0};   /* Input neuron membrane (all neurons are LIF) */
    int32_t mem1[HIDDEN_SIZE] = {0};
    int32_t mem2[OUTPUT_SIZE] = {0};
    int32_t output_spikes_total[OUTPUT_SIZE] = {0};

    for (int t = 0; t < TIMESTEPS; t++) {
        /* Input layer: LIF24 neurons receiving raw-pixel Poisson as current.
         * All neurons including inputs are LIF in this architecture.
         * Poisson hit determines whether current is injected this timestep. */
        for (int i = 0; i < INPUT_SIZE; i++) {
            mem0[i] = (int32_t)(((int64_t)mem0[i] * BETA) >> 8);  /* LIF24 decay */
            if (pixels[i] > (uint8_t)(rand() % 255))
                mem0[i] += THRESHOLD;   /* inject current = threshold (≡ unit current) */
            mem0_hist[t][i] = mem0[i];  /* store pre-spike vmem for BPTT */
            input_spikes_hist[t][i] = (mem0[i] > THRESHOLD);
            if (input_spikes_hist[t][i]) mem0[i] = 0;   /* RESET_ZERO */
        }

        /* Layer 1: LIF24 β=0.75, decay = (V>>1)+(V>>2) = V×192/256 */
        for (int j = 0; j < HIDDEN_SIZE; j++) {
            mem1[j] = (int32_t)(((int64_t)mem1[j] * BETA) >> 8);
            for (int i = 0; i < INPUT_SIZE; i++)
                if (input_spikes_hist[t][i]) mem1[j] += W1[i][j];
            mem1_hist[t][j] = mem1[j];  /* store PRE-SPIKE vmem for dump */
            spikes1_hist[t][j] = (mem1[j] > THRESHOLD);
            if (spikes1_hist[t][j]) mem1[j] = 0;   /* RESET_ZERO */
        }

        /* Layer 2: LIF24, reset-to-zero */
        for (int k = 0; k < OUTPUT_SIZE; k++) {
            mem2[k] = (int32_t)(((int64_t)mem2[k] * BETA) >> 8);
            for (int j = 0; j < HIDDEN_SIZE; j++)
                if (spikes1_hist[t][j]) mem2[k] += W2[j][k];
            mem2_hist[t][k] = mem2[k];  /* store PRE-SPIKE vmem for dump */
            if (mem2[k] > THRESHOLD) {
                spikes2_hist[t][k] = 1;
                output_spikes_total[k]++;
                mem2[k] = 0;
            } else {
                spikes2_hist[t][k] = 0;
            }
        }
    }

    int prediction = 0, max_spikes = -1;
    for (int i = 0; i < OUTPUT_SIZE; i++) {
        if (output_spikes_total[i] > max_spikes) {
            max_spikes = output_spikes_total[i];
            prediction = i;
        }
    }

    int32_t output_rates[OUTPUT_SIZE];
    for (int i = 0; i < OUTPUT_SIZE; i++)
        output_rates[i] = (output_spikes_total[i] * SCALE) / TIMESTEPS;
    backward_pass(label, output_rates);
    return prediction;
}

/* BATCH UPDATE — float shadow weights → re-quantise to int16 */
void apply_batch_update(void) {
    float lr = LR_F / BATCH_SIZE;
    const float w1_max = (float)W1_CLAMP / (float)SCALE;
    const float w2_max = (float)W2_CLAMP / (float)SCALE;

    for (int i = 0; i < INPUT_SIZE; i++) {
        for (int j = 0; j < HIDDEN_SIZE; j++) {
            W1f[i][j] -= lr * dW1_acc[i][j];
            if (W1f[i][j] >  w1_max) W1f[i][j] =  w1_max;
            if (W1f[i][j] < -w1_max) W1f[i][j] = -w1_max;
            W1[i][j] = (int16_t)roundf(W1f[i][j] * (float)SCALE);
        }
    }
    for (int i = 0; i < HIDDEN_SIZE; i++) {
        for (int j = 0; j < OUTPUT_SIZE; j++) {
            W2f[i][j] -= lr * dW2_acc[i][j];
            if (W2f[i][j] >  w2_max) W2f[i][j] =  w2_max;
            if (W2f[i][j] < -w2_max) W2f[i][j] = -w2_max;
            W2[i][j] = (int16_t)roundf(W2f[i][j] * (float)SCALE);
        }
    }
    memset(dW1_acc, 0, sizeof(dW1_acc));
    memset(dW2_acc, 0, sizeof(dW2_acc));
}

int main(void) {
    srand(42);

    /* Kaiming-uniform init in float — within hardware-safe clamps
     * W1: fan_in=784 → ±1/sqrt(784)≈±0.036 → well inside ±0.078
     * W2: fan_in=200 → ±1/sqrt(200)≈±0.071 → well inside ±0.391 */
    for (int i = 0; i < INPUT_SIZE; i++)
        for (int j = 0; j < HIDDEN_SIZE; j++) {
            W1f[i][j] = ((float)rand()/(float)RAND_MAX * 2.0f - 1.0f) * 0.036f;
            W1[i][j]  = (int16_t)roundf(W1f[i][j] * (float)SCALE);
        }
    for (int i = 0; i < HIDDEN_SIZE; i++)
        for (int j = 0; j < OUTPUT_SIZE; j++) {
            W2f[i][j] = ((float)rand()/(float)RAND_MAX * 2.0f - 1.0f) * 0.071f;
            W2[i][j]  = (int16_t)roundf(W2f[i][j] * (float)SCALE);
        }

    memset(dW1_acc, 0, sizeof(dW1_acc));
    memset(dW2_acc, 0, sizeof(dW2_acc));

    printf("Training with HARDWARE-MATCHED parameters:\n");
    printf("  Architecture  : %d → %d → %d\n", INPUT_SIZE, HIDDEN_SIZE, OUTPUT_SIZE);
    printf("  Decay mode    : LIF24  β=0.75  (BETA=%d/256)\n", BETA);
    printf("  Threshold     : 1.0  (int=%d)\n", THRESHOLD);
    printf("  Reset mode    : RESET_ZERO\n");
    printf("  Spike cond.   : > (strictly greater, matches hardware)\n");
    printf("  Input encode  : Raw-pixel Poisson  pixel > rand()%%255\n");
    printf("  W1 clamp      : ±%d  (%.4f float,  Q28-safe)\n", W1_CLAMP, (float)W1_CLAMP/(float)SCALE);
    printf("  W2 clamp      : ±%d  (%.4f float,  Q28-safe)\n", W2_CLAMP, (float)W2_CLAMP/(float)SCALE);
    printf("  LR / batch    : %.5f / %d\n", LR_F, BATCH_SIZE);
    printf("  Epochs        : %d\n\n", EPOCHS);

    dump_vmem_spikes_init();

    uint8_t label, pixels[INPUT_SIZE];

    for (int epoch = 0; epoch < EPOCHS; epoch++) {
        FILE *file = fopen("mnist_full_train.bin", "rb");
        if (!file) { printf("Error opening mnist_full_train.bin\n"); return 1; }

        int count = 0, correct = 0;
        memset(dW1_acc, 0, sizeof(dW1_acc));
        memset(dW2_acc, 0, sizeof(dW2_acc));

        while (fread(&label, 1, 1, file) == 1 &&
               fread(pixels, 1, INPUT_SIZE, file) == INPUT_SIZE) {

            int pred = train_on_sample_with_result(label, pixels);
            dump_vmem_spikes_sample();  /* Dump vmem/spikes for every sample when -DDUMP_VMEM_SPIKES */
            if (pred == (int)label) correct++;
            count++;

            if (count % BATCH_SIZE == 0)
                apply_batch_update();

            if (count % 1000 == 0) {
                float acc = (float)correct / count * 100.0f;
                float mw1f = 0.0f, mw2f = 0.0f;
                for (int i=0;i<INPUT_SIZE;i++) for(int j=0;j<HIDDEN_SIZE;j++) { float a=fabsf(W1f[i][j]); if(a>mw1f) mw1f=a; }
                for (int i=0;i<HIDDEN_SIZE;i++) for(int j=0;j<OUTPUT_SIZE;j++) { float a=fabsf(W2f[i][j]); if(a>mw2f) mw2f=a; }
                printf("Epoch %d | %5d/60000 | acc=%.2f%% | maxW1f=%.4f maxW2f=%.4f\n",
                       epoch+1, count, acc, mw1f, mw2f);
                report_weight_saturation("mid-epoch");
                if (acc > best_accuracy) {
                    best_accuracy = acc;
                    save_weights_txt("best_weights_hw.txt");
                }
            }
        }
        fclose(file);

        float ep_acc = (float)correct / count * 100.0f;
        printf("Epoch %d DONE | acc=%.2f%%\n\n", epoch + 1, ep_acc);
        report_weight_saturation("epoch-end");
        if (ep_acc > best_accuracy) {
            best_accuracy = ep_acc;
            save_weights_txt("best_weights_hw.txt");
        }
    }

    printf("Training complete. Best accuracy: %.2f%%\n\n", best_accuracy);
    dump_vmem_spikes_close();

    printf("Convert weights for hardware inference:\n");
    printf("  cd ../../tools/weights\n");
    printf("  python3 convert_ccode_weights_to_datamem.py \\\n");
    printf("    ../../RISC_V/c_program/best_weights_hw.txt \\\n");
    printf("    -o ../../inference_accelarator/neuron_accelerator/data_mem_mnist_new.mem \\\n");
    printf("    --int-scale 256 --decay lif24 --reset-mode zero\n");
    return 0;
}

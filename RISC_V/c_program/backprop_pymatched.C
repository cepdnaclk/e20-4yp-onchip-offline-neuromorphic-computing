/*
 * backprop_pymatched.C  —  Hybrid-quantised SNN training (matches Python pipeline)
 * =================================================================================
 *
 * PURPOSE
 * -------
 * Validates the full C→data_mem.mem→hardware pipeline by training with
 * EXACTLY the same parameters as the Python model that already works on hardware.
 * If this model matches Python accuracy on hardware, the pipeline is confirmed
 * correct and any remaining gap with backpropD_hw.C is a parameter issue.
 *
 * MODEL PARAMETERS  (mirror run_smnist_pipeline.sh defaults)
 * -----------------------------------------------------------
 *   Architecture : 784 → 16 → 10
 *   Decay mode   : LIF2   β = 0.5  (hardware `LIF2 mode)
 *   Threshold    : 1.0  = 256/SCALE
 *   Reset        : RESET_ZERO
 *   Timesteps    : 16
 *   Input encode : Normalised Poisson  (same as smnist_convert_test.py)
 *                  p = clamp((px/255 − 0.1307) / 0.3081, 0, 1)
 *
 * HYBRID QUANTISATION
 * -------------------
 *   Forward pass  → INTEGER arithmetic  (exactly replicates hardware)
 *   Backward pass → FLOAT arithmetic    (prevents gradient truncation to 0)
 *
 *   WHY FLOAT BACKWARD?
 *   With SCALE=256 and small weights (~±10 int), the integer gradient chain:
 *     delta1 = (error × surrogate_grad) >> 8  ≈  (6 × 10 × 256/256) >> 8 = 0
 *   truncates to zero every step — the network never learns.
 *   Float backward is identical to how PyTorch trains with a surrogate gradient.
 *
 * HARDWARE SAFETY  (Q28 overflow prevention)
 * -------------------------------------------
 *   Hardware Q4.28 register max:   7.999 float
 *   With up to ~100 simultaneous inputs active at once:
 *     max safe W1 float = 7.999/100 = 0.080 → int = 20   (W1_CLAMP=20)
 *   With up to 16 hidden neurons firing at once:
 *     max safe W2 float = 7.999/16  = 0.500 → int = 128  (W2_CLAMP=100, conservative)
 *
 * BUILD
 *   gcc -O2 -Wall -o backprop_pymatched backprop_pymatched.C -lm
 *
 * RUN
 *   ./backprop_pymatched
 *   (needs mnist_full_train.bin — generate: python3 ../../tools/prepare_mnist_data.py)
 *
 * CONVERT WEIGHTS → data_mem
 *   cd ../../tools/weights
 *   python3 convert_ccode_weights_to_datamem.py \
 *       ../../RISC_V/c_program/best_weights_pymatched.txt \
 *       -o ../../inference_accelarator/neuron_accelerator/data_mem_pymatched.mem \
 *       --int-scale 256 --decay lif2 --reset-mode zero
 *
 * TESTBENCH: uncomment `define WEIGHT_SOURCE_C_PYMATCHED  (Option C)
 */

#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>

/* ─────────────────────────── Architecture ──────────────────────────────── */
#define TIMESTEPS    16
#define INPUT_SIZE   784
#define HIDDEN_SIZE  16
#define OUTPUT_SIZE  10

/* ──────────────────────────── Fixed-point scale ────────────────────────── */
#define SCALE        256
#define THRESHOLD    (1 * SCALE)   /* 1.0 float = 256 integer               */

/* ─────── Hardware-safe weight clamps (Q4.28 overflow prevention) ─────── */
/* Q28 max ≈ 7.999. W1: up to ~100 inputs active → clamp = 7.999/100×256 ≈ 20  */
/* W2: up to 16 hidden active              → clamp = 7.999/16 ×256 ≈ 128       */
#define W1_CLAMP     20
#define W2_CLAMP     100

/* ─────────────────────────── Training hyperparams ──────────────────────── */
#define EPOCHS       10
#define BATCH_SIZE   32
#define LR_F         0.005f        /* float learning rate                    */

/* ────────────────────────── Normalisation constants ───────────────────── */
#define NORM_MEAN    0.1307f
#define NORM_STD     0.3081f

/* ─────────────────────────────── Weights ──────────────────────────────── */
/* Shadow float weights: accumulate real-valued gradient steps               */
/* (avoids int16 update truncation: step=0.000008 < 1/SCALE=0.004 → never   */
/*  changes int16 without accumulation in float first)                       */
float   W1f[INPUT_SIZE][HIDDEN_SIZE];
float   W2f[HIDDEN_SIZE][OUTPUT_SIZE];
/* Quantised int16 derived from float shadows — used in integer forward pass */
int16_t W1[INPUT_SIZE][HIDDEN_SIZE];
int16_t W2[HIDDEN_SIZE][OUTPUT_SIZE];

/* Float gradient accumulators — reset each batch */
float dW1_acc[INPUT_SIZE][HIDDEN_SIZE];
float dW2_acc[HIDDEN_SIZE][OUTPUT_SIZE];

/* Spike histories for BPTT */
uint8_t input_spikes[TIMESTEPS][INPUT_SIZE];
uint8_t hidden_spikes[TIMESTEPS][HIDDEN_SIZE];
uint8_t output_spikes[TIMESTEPS][OUTPUT_SIZE];

/* Input neuron vmem history — all neurons are LIF including inputs.
 * The input current (normalised Poisson hit) drives mem0 through LIF dynamics.
 * Needed for surrogate gradient chain in BPTT through the input layer. */
int32_t mem0_hist[TIMESTEPS][INPUT_SIZE];

/* Hidden and output vmem history — captured BEFORE spike check and reset.
 * Used to dump actual LUT indices to compare with hardware. */
int32_t mem1_hist[TIMESTEPS][HIDDEN_SIZE];
int32_t mem2_hist[TIMESTEPS][OUTPUT_SIZE];

float best_accuracy = 0.0f;

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
    /* Header: sample, ts, [784 input spikes], [16 h spikes], [10 o spikes], [16 h lut_idx], [10 o lut_idx] */
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
            fprintf(dump_file, ",%d", input_spikes[t][i]);

        /* Hidden spikes (16) */
        for (int j = 0; j < HIDDEN_SIZE; j++)
            fprintf(dump_file, ",%d", hidden_spikes[t][j]);

        /* Output spikes (10) */
        for (int k = 0; k < OUTPUT_SIZE; k++)
            fprintf(dump_file, ",%d", output_spikes[t][k]);

        /* Hidden LUT indices (16) — convert saved vmem to LUT index */
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

/* ═══════════════════════════════════════════════════════════════════════════
 * Normalised Poisson encoding — mirrors smnist_convert_test.py exactly.
 * p = clamp((px/255 − 0.1307) / 0.3081, 0, 1)  then Bernoulli(p)
 * ═══════════════════════════════════════════════════════════════════════════ */
static inline uint8_t poisson_spike(uint8_t px)
{
    float p = ((float)px / 255.0f - NORM_MEAN) / NORM_STD;
    if (p < 0.0f) p = 0.0f;
    if (p > 1.0f) p = 1.0f;
    return ((float)rand() / (float)RAND_MAX < p) ? 1u : 0u;
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Float surrogate gradient — fast sigmoid: 1 / (1 + 4|v - v_t|)^2
 * Input: integer membrane potential (in SCALE units)
 * ═══════════════════════════════════════════════════════════════════════════ */
static inline float surrogate_grad_f(int32_t mem_int)
{
    float v   = (float)mem_int / (float)SCALE;
    float vt  = (float)THRESHOLD / (float)SCALE;  /* = 1.0 */
    float den = 1.0f + 4.0f * fabsf(v - vt);
    return 1.0f / (den * den);
}

/* ═══════════════════════════════════════════════════════════════════════════
 * FORWARD PASS — integer arithmetic, exactly replicates hardware.
 * Stores spike histories in input_spikes / hidden_spikes / output_spikes.
 * Returns predicted digit (max output spike count).
 * ═══════════════════════════════════════════════════════════════════════════ */
static int forward_pass(const uint8_t *pixels)
{
    int32_t mem0[INPUT_SIZE]  = {0};   /* Input neuron membrane (all neurons are LIF) */
    int32_t mem1[HIDDEN_SIZE] = {0};
    int32_t mem2[OUTPUT_SIZE] = {0};
    int     out_total[OUTPUT_SIZE] = {0};

    for (int t = 0; t < TIMESTEPS; t++) {
        /* Input layer: LIF2 neurons receiving normalised Poisson as current.
         * All neurons including inputs are LIF in this architecture. */
        for (int i = 0; i < INPUT_SIZE; i++) {
            mem0[i] = ((int64_t)mem0[i] * 128) >> 8;  /* LIF2 decay = V>>1 */
            if (poisson_spike(pixels[i]))
                mem0[i] += THRESHOLD;   /* inject current = threshold (≡ unit current) */
            mem0_hist[t][i] = mem0[i];  /* store pre-spike vmem for BPTT */
            input_spikes[t][i] = (mem0[i] > THRESHOLD);
            if (input_spikes[t][i]) mem0[i] = 0;   /* RESET_ZERO */
        }

        /* Hidden layer — LIF2: decay = V>>1 (V × 128/256), reset-to-zero */
        for (int j = 0; j < HIDDEN_SIZE; j++) {
            mem1[j] = ((int64_t)mem1[j] * 128) >> 8;
            for (int i = 0; i < INPUT_SIZE; i++)
                if (input_spikes[t][i]) mem1[j] += W1[i][j];
            mem1_hist[t][j] = mem1[j];  /* store PRE-SPIKE vmem for dump */
            hidden_spikes[t][j] = (mem1[j] > THRESHOLD);
            if (hidden_spikes[t][j]) mem1[j] = 0;   /* RESET_ZERO */
        }

        /* Output layer — LIF2, reset-to-zero */
        for (int k = 0; k < OUTPUT_SIZE; k++) {
            mem2[k] = ((int64_t)mem2[k] * 128) >> 8;
            for (int j = 0; j < HIDDEN_SIZE; j++)
                if (hidden_spikes[t][j]) mem2[k] += W2[j][k];
            mem2_hist[t][k] = mem2[k];  /* store PRE-SPIKE vmem for dump */
            output_spikes[t][k] = (mem2[k] > THRESHOLD);
            if (output_spikes[t][k]) { mem2[k] = 0; out_total[k]++; }
        }
    }

    int pred = 0, mx = -1;
    for (int k = 0; k < OUTPUT_SIZE; k++)
        if (out_total[k] > mx) { mx = out_total[k]; pred = k; }
    return pred;
}

/* ═══════════════════════════════════════════════════════════════════════════
 * BACKWARD PASS — FLOAT arithmetic (avoids integer truncation to zero).
 * Uses spike-rate MSE loss and BPTT with fast-sigmoid surrogate gradient.
 * Accumulates into dW1_acc / dW2_acc (caller resets per batch).
 * ═══════════════════════════════════════════════════════════════════════════ */
static void backward_pass(uint8_t label)
{
    /* Output spike rates for this sample */
    float out_rate[OUTPUT_SIZE];
    for (int k = 0; k < OUTPUT_SIZE; k++) {
        int cnt = 0;
        for (int t = 0; t < TIMESTEPS; t++) cnt += output_spikes[t][k];
        out_rate[k] = (float)cnt / TIMESTEPS;
    }

    /* MSE output error */
    float delta_out[OUTPUT_SIZE];
    for (int k = 0; k < OUTPUT_SIZE; k++) {
        float y = (k == (int)label) ? 1.0f : 0.0f;
        delta_out[k] = 2.0f * (out_rate[k] - y);
    }

    float dm2[OUTPUT_SIZE] = {0};
    float dm1[HIDDEN_SIZE] = {0};
    float dm0[INPUT_SIZE]  = {0};   /* input layer temporal gradient (all neurons are LIF) */

    for (int t = TIMESTEPS - 1; t >= 0; t--) {
        float new_dm2[OUTPUT_SIZE] = {0};
        float new_dm1[HIDDEN_SIZE] = {0};
        float new_dm0[INPUT_SIZE]  = {0};

        /* ── Output layer ── */
        for (int k = 0; k < OUTPUT_SIZE; k++) {
            /* Approximate pre-spike membrane: fired→just above threshold, else≈0 */
            int32_t vmem_k = output_spikes[t][k] ? (THRESHOLD + 1) : 0;
            float sg = surrogate_grad_f(vmem_k);
            float d2 = (delta_out[k] + 0.5f * dm2[k]) * sg;

            /* Weight gradient: W2[j][k] ← dL/d(W2[j][k]) */
            for (int j = 0; j < HIDDEN_SIZE; j++)
                if (hidden_spikes[t][j])
                    dW2_acc[j][k] += d2;

            /* Error to hidden layer */
            for (int j = 0; j < HIDDEN_SIZE; j++)
                new_dm1[j] += d2 * W2f[j][k];

            new_dm2[k] = d2 * (1.0f - (float)output_spikes[t][k]);
        }

        /* ── Hidden layer ── */
        for (int j = 0; j < HIDDEN_SIZE; j++) {
            int32_t vmem_j = hidden_spikes[t][j] ? (THRESHOLD + 1) : 0;
            float sg = surrogate_grad_f(vmem_j);
            float d1 = (new_dm1[j] + 0.5f * dm1[j]) * sg;

            for (int i = 0; i < INPUT_SIZE; i++)
                if (input_spikes[t][i])
                    dW1_acc[i][j] += d1;

            /* Error propagated to input layer (for input LIF temporal gradient) */
            for (int i = 0; i < INPUT_SIZE; i++)
                new_dm0[i] += d1 * W1f[i][j];

            new_dm1[j] = d1 * (1.0f - (float)hidden_spikes[t][j]);
        }

        /* ── Input layer — all neurons are LIF, so BPTT temporal gradient applies.
         * No weights to update before input, but the temporal chain dm0 correctly
         * gates gradient flow through the input membrane potential. ── */
        for (int i = 0; i < INPUT_SIZE; i++) {
            float sg0 = surrogate_grad_f(mem0_hist[t][i]);
            float d0 = (new_dm0[i] + 0.5f * dm0[i]) * sg0;
            new_dm0[i] = d0 * (1.0f - (float)input_spikes[t][i]);
        }

        for (int k = 0; k < OUTPUT_SIZE; k++) dm2[k] = new_dm2[k];
        for (int j = 0; j < HIDDEN_SIZE; j++) dm1[j] = new_dm1[j];
        for (int i = 0; i < INPUT_SIZE; i++) dm0[i] = new_dm0[i];
    }
}

/* ═══════════════════════════════════════════════════════════════════════════
 * BATCH UPDATE — convert float gradients → int16 with clamping
 * ═══════════════════════════════════════════════════════════════════════════ */
static void apply_batch_update(void)
{
    float lr = LR_F / BATCH_SIZE;
    const float w1_max = (float)W1_CLAMP / (float)SCALE;   /* 0.0781 */
    const float w2_max = (float)W2_CLAMP / (float)SCALE;   /* 0.3906 */

    /* Update float shadow weights, then re-quantise to int16.             */
    /* Float shadows accumulate tiny steps (e.g. 0.000008) until they      */
    /* cross a quantisation boundary (1/SCALE = 0.00390625), at which      */
    /* point int16 flips — exactly like fixed-point QAT.                   */
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

/* ═══════════════════════════════════════════════════════════════════════════
 * SAVE WEIGHTS — Format A (compatible with convert_ccode_weights_to_datamem.py)
 * ═══════════════════════════════════════════════════════════════════════════ */
static void save_weights(const char *fn)
{
    FILE *f = fopen(fn, "w");
    if (!f) { printf("Error: cannot open %s\n", fn); return; }
    fprintf(f, "W1 Weights (%d x %d):\n", INPUT_SIZE, HIDDEN_SIZE);
    for (int i = 0; i < INPUT_SIZE; i++) {
        for (int j = 0; j < HIDDEN_SIZE; j++) fprintf(f, "%d ", (int)W1[i][j]);
        fprintf(f, "\n");
    }
    fprintf(f, "\n-------------------------------------\n\n");
    fprintf(f, "W2 Weights (%d x %d):\n", HIDDEN_SIZE, OUTPUT_SIZE);
    for (int i = 0; i < HIDDEN_SIZE; i++) {
        for (int j = 0; j < OUTPUT_SIZE; j++) fprintf(f, "%d ", (int)W2[i][j]);
        fprintf(f, "\n");
    }
    fclose(f);
    printf(" >>> Saved weights to %s <<<\n", fn);
}

/* ═══════════════════════════════════════════════════════════════════════════
 * MAIN
 * ═══════════════════════════════════════════════════════════════════════════ */
int main(void)
{
    srand(42);  /* fixed seed for reproducibility */

    /*
     * Kaiming-uniform-like init scaled for hardware clamps:
     * W1: fan_in=784 → std≈1/sqrt(784)≈0.036 → ×SCALE≈9 → uniform ±15
     * W2: fan_in=16  → std≈1/sqrt(16) =0.25  → ×SCALE=64 → uniform ±63
     */
    /* Kaiming-uniform-like init in float, then quantise to int16.          */
    /* fan_in=784 → W1 uniform ±0.05  (well within ±0.0781 clamp)           */
    /* fan_in=16  → W2 uniform ±0.30  (well within ±0.3906 clamp)           */
    for (int i = 0; i < INPUT_SIZE; i++)
        for (int j = 0; j < HIDDEN_SIZE; j++) {
            W1f[i][j] = ((float)rand() / (float)RAND_MAX * 2.0f - 1.0f) * 0.05f;
            W1[i][j]  = (int16_t)roundf(W1f[i][j] * (float)SCALE);
        }
    for (int i = 0; i < HIDDEN_SIZE; i++)
        for (int j = 0; j < OUTPUT_SIZE; j++) {
            W2f[i][j] = ((float)rand() / (float)RAND_MAX * 2.0f - 1.0f) * 0.30f;
            W2[i][j]  = (int16_t)roundf(W2f[i][j] * (float)SCALE);
        }

    memset(dW1_acc, 0, sizeof(dW1_acc));
    memset(dW2_acc, 0, sizeof(dW2_acc));

    printf("=================================================================\n");
    printf("  backprop_pymatched  (integer-forward / float-backward)\n");
    printf("=================================================================\n");
    printf("  Architecture  : %d → %d → %d\n", INPUT_SIZE, HIDDEN_SIZE, OUTPUT_SIZE);
    printf("  Decay         : LIF2  β=0.5\n");
    printf("  Threshold     : 1.0  (int=%d)\n", THRESHOLD);
    printf("  Reset         : RESET_ZERO\n");
    printf("  Timesteps     : %d\n", TIMESTEPS);
    printf("  Input encode  : Normalised Poisson (mean=%.4f std=%.4f)\n",
           NORM_MEAN, NORM_STD);
    printf("  W1 clamp      : ±%d  (%.4f float)\n", W1_CLAMP, (float)W1_CLAMP/(float)SCALE);
    printf("  W2 clamp      : ±%d  (%.4f float)\n", W2_CLAMP, (float)W2_CLAMP/(float)SCALE);
    printf("  LR / batch    : %.5f / %d\n", LR_F, BATCH_SIZE);
    printf("=================================================================\n\n");

    dump_vmem_spikes_init();

    uint8_t label, pixels[INPUT_SIZE];

    for (int epoch = 0; epoch < EPOCHS; epoch++) {
        FILE *fp = fopen("mnist_full_train.bin", "rb");
        if (!fp) {
            printf("ERROR: mnist_full_train.bin not found.\n");
            printf("  Generate: python3 ../../tools/prepare_mnist_data.py\n");
            return 1;
        }

        int count = 0, correct = 0;
        memset(dW1_acc, 0, sizeof(dW1_acc));
        memset(dW2_acc, 0, sizeof(dW2_acc));

        while (fread(&label, 1, 1, fp) == 1 &&
               fread(pixels, 1, INPUT_SIZE, fp) == INPUT_SIZE) {

            int pred = forward_pass(pixels);
            dump_vmem_spikes_sample();  /* Dump vmem/spikes for every sample when -DDUMP_VMEM_SPIKES */
            if (pred == (int)label) correct++;
            backward_pass(label);
            count++;

            if (count % BATCH_SIZE == 0)
                apply_batch_update();

            /* Check every 1000 samples — same cadence as original backpropD_hw.C */
            if (count % 1000 == 0) {
                float acc = 100.0f * correct / count;
                float mw1f = 0.0f, mw2f = 0.0f;
                for (int i=0;i<INPUT_SIZE;i++) for(int j=0;j<HIDDEN_SIZE;j++) { float a=fabsf(W1f[i][j]); if(a>mw1f) mw1f=a; }
                for (int i=0;i<HIDDEN_SIZE;i++) for(int j=0;j<OUTPUT_SIZE;j++) { float a=fabsf(W2f[i][j]); if(a>mw2f) mw2f=a; }
                printf("Ep %d | %5d/60000 | acc=%.2f%% | maxW1f=%.4f maxW2f=%.4f\n",
                       epoch+1, count, acc, mw1f, mw2f);
                /* Save best weights mid-epoch — same behaviour as original */
                if (acc > best_accuracy) {
                    best_accuracy = acc;
                    save_weights("best_weights_pymatched.txt");
                }
            }
        }
        fclose(fp);

        float ep_acc = 100.0f * correct / count;
        printf("Epoch %d DONE | acc=%.2f%%\n\n", epoch + 1, ep_acc);
        /* Also check at exact epoch end */
        if (ep_acc > best_accuracy) {
            best_accuracy = ep_acc;
            save_weights("best_weights_pymatched.txt");
        }
    }

    printf("Training complete. Best accuracy: %.2f%%\n\n", best_accuracy);
    dump_vmem_spikes_close();

    printf("Convert weights:\n");
    printf("  cd ../../tools/weights\n");
    printf("  python3 convert_ccode_weights_to_datamem.py \\\n");
    printf("    ../../RISC_V/c_program/best_weights_pymatched.txt \\\n");
    printf("    -o ../../inference_accelarator/neuron_accelerator/data_mem_pymatched.mem \\\n");
    printf("    --int-scale 256 --decay lif2 --reset-mode zero\n");
    return 0;
}

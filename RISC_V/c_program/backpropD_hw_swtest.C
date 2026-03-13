#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define TIMESTEPS    16
#define INPUT_SIZE   784
#define HIDDEN_SIZE  200
#define OUTPUT_SIZE  10
#define SCALE        256
#define THRESHOLD    (1 * SCALE)
#define BETA         192

static int16_t W1[INPUT_SIZE][HIDDEN_SIZE];
static int16_t W2[HIDDEN_SIZE][OUTPUT_SIZE];

static uint8_t input_spikes_hist[TIMESTEPS][INPUT_SIZE];
static uint8_t spikes1_hist[TIMESTEPS][HIDDEN_SIZE];
static uint8_t spikes2_hist[TIMESTEPS][OUTPUT_SIZE];
static int32_t mem1_hist[TIMESTEPS][HIDDEN_SIZE];
static int32_t mem2_hist[TIMESTEPS][OUTPUT_SIZE];

static inline uint8_t vmem_to_lut_index(int32_t mem) {
    float v = (float)mem / (float)SCALE;
    int32_t v_int = (int32_t)v;
    if (v_int > 127) v_int = 127;
    if (v_int < -128) v_int = -128;
    return (uint8_t)(v_int + 128);
}

static int load_weights_txt(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) {
        fprintf(stderr, "Error: cannot open weights file: %s\n", path);
        return 0;
    }

    long total_w1 = (long)INPUT_SIZE * HIDDEN_SIZE;
    long total_w2 = (long)HIDDEN_SIZE * OUTPUT_SIZE;
    long count = 0;

    char line[4096];
    while (fgets(line, sizeof(line), f)) {
        char *p = line;
        while (*p) {
            char *end = NULL;
            long v = strtol(p, &end, 10);
            if (end == p) {
                p++;
                continue;
            }
            if (count < total_w1) {
                long idx = count;
                W1[idx / HIDDEN_SIZE][idx % HIDDEN_SIZE] = (int16_t)v;
            } else if (count < total_w1 + total_w2) {
                long idx = count - total_w1;
                W2[idx / OUTPUT_SIZE][idx % OUTPUT_SIZE] = (int16_t)v;
            }
            count++;
            p = end;
        }
    }
    fclose(f);

    if (count < total_w1 + total_w2) {
        fprintf(stderr, "Error: weights file incomplete (%ld/%ld ints)\n",
                count, total_w1 + total_w2);
        return 0;
    }
    return 1;
}

static int read_spike_mem_block(FILE *f, int sample, int timesteps) {
    char line[64];
    int warned = 0;

    for (int t = 0; t < timesteps; t++) {
        for (int i = 0; i < INPUT_SIZE; i++) {
            if (!fgets(line, sizeof(line), f)) {
                fprintf(stderr, "Error: spike_mem ended early at sample=%d ts=%d nid=%d\n",
                        sample, t, i);
                return 0;
            }
            unsigned val = 0;
            if (sscanf(line, "%x", &val) != 1) {
                fprintf(stderr, "Error: invalid spike_mem line: %s\n", line);
                return 0;
            }
            if ((val & 0x7FF) == 0x7FF) {
                input_spikes_hist[t][i] = 0;
            } else {
                input_spikes_hist[t][i] = 1;
                if (!warned) {
                    unsigned nid = ((val >> 5) & 0x3F) * 32 + (val & 0x1F);
                    if ((int)nid != i) {
                        fprintf(stderr,
                                "Warning: spike packet nid mismatch at sample=%d ts=%d idx=%d (pkt nid=%u)\n",
                                sample, t, i, nid);
                        warned = 1;
                    }
                }
            }
        }
    }
    return 1;
}

static void forward_pass_from_spikes(void) {
    int32_t mem1[HIDDEN_SIZE];
    int32_t mem2[OUTPUT_SIZE];

    memset(mem1, 0, sizeof(mem1));
    memset(mem2, 0, sizeof(mem2));

    for (int t = 0; t < TIMESTEPS; t++) {
        for (int j = 0; j < HIDDEN_SIZE; j++) {
            mem1[j] = (int32_t)(((int64_t)mem1[j] * BETA) >> 8);
            for (int i = 0; i < INPUT_SIZE; i++) {
                if (input_spikes_hist[t][i]) mem1[j] += W1[i][j];
            }
            mem1_hist[t][j] = mem1[j];
            spikes1_hist[t][j] = (mem1[j] > THRESHOLD);
            if (spikes1_hist[t][j]) mem1[j] = 0;
        }

        for (int k = 0; k < OUTPUT_SIZE; k++) {
            mem2[k] = (int32_t)(((int64_t)mem2[k] * BETA) >> 8);
            for (int j = 0; j < HIDDEN_SIZE; j++) {
                if (spikes1_hist[t][j]) mem2[k] += W2[j][k];
            }
            mem2_hist[t][k] = mem2[k];
            if (mem2[k] > THRESHOLD) {
                spikes2_hist[t][k] = 1;
                mem2[k] = 0;
            } else {
                spikes2_hist[t][k] = 0;
            }
        }
    }
}

static void write_csv_header(FILE *out) {
    fprintf(out, "sample,ts");
    for (int i = 0; i < INPUT_SIZE; i++) fprintf(out, ",inp_%d", i);
    for (int i = 0; i < HIDDEN_SIZE; i++) fprintf(out, ",spike_h%d", i);
    for (int i = 0; i < OUTPUT_SIZE; i++) fprintf(out, ",spike_o%d", i);
    for (int i = 0; i < HIDDEN_SIZE; i++) fprintf(out, ",vmem_h%d", i);
    for (int i = 0; i < OUTPUT_SIZE; i++) fprintf(out, ",vmem_o%d", i);
    fprintf(out, "\n");
}

static void write_csv_sample(FILE *out, int sample) {
    for (int t = 0; t < TIMESTEPS; t++) {
        fprintf(out, "%d,%d", sample, t);
        for (int i = 0; i < INPUT_SIZE; i++) fprintf(out, ",%d", input_spikes_hist[t][i]);
        for (int j = 0; j < HIDDEN_SIZE; j++) fprintf(out, ",%d", spikes1_hist[t][j]);
        for (int k = 0; k < OUTPUT_SIZE; k++) fprintf(out, ",%d", spikes2_hist[t][k]);
        for (int j = 0; j < HIDDEN_SIZE; j++) fprintf(out, ",%u", vmem_to_lut_index(mem1_hist[t][j]));
        for (int k = 0; k < OUTPUT_SIZE; k++) fprintf(out, ",%u", vmem_to_lut_index(mem2_hist[t][k]));
        fprintf(out, "\n");
    }
}

int main(int argc, char **argv) {
    const char *weights_path = "best_weights_hw.txt";
    const char *spike_mem_path = "../../inference_accelarator/neuron_accelerator/spike_mem_mnist.mem";
    const char *out_path = "software_vmem_spikes.csv";
    int samples = 320;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--weights") && i + 1 < argc) weights_path = argv[++i];
        else if (!strcmp(argv[i], "--spike_mem") && i + 1 < argc) spike_mem_path = argv[++i];
        else if (!strcmp(argv[i], "--out") && i + 1 < argc) out_path = argv[++i];
        else if (!strcmp(argv[i], "--samples") && i + 1 < argc) samples = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--help")) {
            printf("Usage: %s [--weights FILE] [--spike_mem FILE] [--out FILE] [--samples N]\n", argv[0]);
            return 0;
        }
    }

    if (!load_weights_txt(weights_path)) return 1;

    FILE *spike_f = fopen(spike_mem_path, "r");
    if (!spike_f) {
        fprintf(stderr, "Error: cannot open spike_mem file: %s\n", spike_mem_path);
        return 1;
    }

    FILE *out = fopen(out_path, "w");
    if (!out) {
        fprintf(stderr, "Error: cannot open output file: %s\n", out_path);
        fclose(spike_f);
        return 1;
    }

    write_csv_header(out);

    for (int s = 0; s < samples; s++) {
        if (!read_spike_mem_block(spike_f, s, TIMESTEPS)) {
            fclose(spike_f);
            fclose(out);
            return 1;
        }
        forward_pass_from_spikes();
        write_csv_sample(out, s);
        if ((s + 1) % 10 == 0) {
            printf("Processed %d/%d samples\n", s + 1, samples);
        }
    }

    fclose(spike_f);
    fclose(out);
    printf("Wrote %s (%d samples)\n", out_path, samples);
    return 0;
}

//
//  dab_fec.c
//  RTL-SDR Host
//
//  See dab_fec.h.
//

#include "dab_fec.h"

#include <string.h>

// MARK: - Viterbi

// Encoder register r: bit 6 is the current input bit a(i), bit 0 is a(i-6).
// The state is the 6 most recent inputs, r >> 1 after a step.
static const uint8_t generators[4] = { 0133, 0171, 0145, 0133 };

static uint8_t branch_output[128];   // 4 code bits for register value r
static int branch_ready;

static void viterbi_init(void) {
    if (branch_ready) return;
    for (int r = 0; r < 128; r++) {
        uint8_t out = 0;
        for (int g = 0; g < 4; g++) {
            out |= (uint8_t)(__builtin_parity(r & generators[g]) << g);
        }
        branch_output[r] = out;
    }
    branch_ready = 1;
}

size_t dab_viterbi_work_size(size_t bits) {
    return (bits + 6) * sizeof(uint64_t) + 2 * 64 * sizeof(int32_t);
}

void dab_viterbi(const int8_t *soft, size_t bits, uint8_t *out, void *work) {
    viterbi_init();
    const size_t steps = bits + 6;
    uint64_t *decisions = (uint64_t *)work;
    int32_t *metric = (int32_t *)(decisions + steps);
    int32_t *next = metric + 64;

    for (int s = 0; s < 64; s++) metric[s] = s == 0 ? 0 : -(1 << 28);

    for (size_t t = 0; t < steps; t++) {
        const int8_t *y = soft + 4 * t;
        // Correlation of the received soft values with each 4-bit pattern.
        int32_t pattern[16];
        for (int p = 0; p < 16; p++) {
            pattern[p] = ((p & 1) ? -y[0] : y[0]) + ((p & 2) ? -y[1] : y[1])
                       + ((p & 4) ? -y[2] : y[2]) + ((p & 8) ? -y[3] : y[3]);
        }
        uint64_t decision = 0;
        for (int ns = 0; ns < 64; ns++) {
            const int u = ns >> 5;
            const int p0 = (ns & 31) << 1, p1 = p0 | 1;
            const int32_t m0 = metric[p0] + pattern[branch_output[(u << 6) | p0]];
            const int32_t m1 = metric[p1] + pattern[branch_output[(u << 6) | p1]];
            if (m1 > m0) {
                next[ns] = m1;
                decision |= (uint64_t)1 << ns;
            } else {
                next[ns] = m0;
            }
        }
        decisions[t] = decision;
        int32_t *swap = metric; metric = next; next = swap;
        // Keep the metrics bounded on long blocks.
        if ((t & 1023) == 1023) {
            int32_t top = metric[0];
            for (int s = 1; s < 64; s++) if (metric[s] > top) top = metric[s];
            for (int s = 0; s < 64; s++) metric[s] -= top;
        }
    }

    // The tail returns the encoder to state 0.
    int state = 0;
    for (size_t t = steps; t-- > 0;) {
        const int bit = state >> 5;
        if (t < bits) out[t] = (uint8_t)bit;
        const int b = (int)((decisions[t] >> state) & 1);
        state = ((state & 31) << 1) | b;
    }
}

// MARK: - Reed-Solomon

static uint8_t gf_exp[512];
static uint8_t gf_log[256];
static uint8_t rs_generator[11];        // g(x), highest degree first
static int rs_ready;

static void rs_init(void) {
    if (rs_ready) return;
    int x = 1;
    for (int i = 0; i < 255; i++) {
        gf_exp[i] = (uint8_t)x;
        gf_log[x] = (uint8_t)i;
        x <<= 1;
        if (x & 0x100) x ^= 0x11D;
    }
    for (int i = 255; i < 512; i++) gf_exp[i] = gf_exp[i - 255];

    // g(x) = (x + α^0)(x + α^1) … (x + α^9)
    uint8_t g[11] = { 1 };
    int degree = 0;
    for (int j = 0; j < 10; j++) {
        uint8_t n[11] = { 0 };
        for (int i = 0; i <= degree; i++) {
            n[i] ^= g[i];                                     // × x
            if (g[i]) n[i + 1] ^= gf_exp[gf_log[g[i]] + j];   // × α^j
        }
        degree++;
        memcpy(g, n, sizeof g);
    }
    memcpy(rs_generator, g, sizeof g);
    rs_ready = 1;
}

static inline uint8_t gf_mul(uint8_t a, uint8_t b) {
    return (a && b) ? gf_exp[gf_log[a] + gf_log[b]] : 0;
}

static inline uint8_t gf_div(uint8_t a, uint8_t b) {
    return a ? gf_exp[gf_log[a] + 255 - gf_log[b]] : 0;
}

void dab_rs_encode(const uint8_t data[110], uint8_t parity[10]) {
    rs_init();
    uint8_t r[10] = { 0 };
    for (int i = 0; i < 110; i++) {
        const uint8_t feedback = data[i] ^ r[0];
        memmove(r, r + 1, 9);
        r[9] = 0;
        if (feedback) {
            for (int j = 0; j < 10; j++) r[j] ^= gf_mul(feedback, rs_generator[j + 1]);
        }
    }
    memcpy(parity, r, 10);
}

int dab_rs_decode(uint8_t c[120]) {
    rs_init();
    // The shortened code is the full one with 135 leading zeros: byte i is
    // the coefficient of x^(119 - i).
    uint8_t syndrome[10];
    int nonzero = 0;
    for (int j = 0; j < 10; j++) {
        uint8_t s = 0;
        for (int i = 0; i < 120; i++) s = gf_mul(s, gf_exp[j]) ^ c[i];
        syndrome[j] = s;
        nonzero |= s;
    }
    if (!nonzero) return 0;

    // Berlekamp-Massey: error locator Λ(x), lowest degree first.
    uint8_t lambda[11] = { 1 }, prev[11] = { 1 };
    int L = 0, m = 1;
    uint8_t b = 1;
    for (int n = 0; n < 10; n++) {
        uint8_t d = syndrome[n];
        for (int i = 1; i <= L; i++) d ^= gf_mul(lambda[i], syndrome[n - i]);
        if (d == 0) {
            m++;
            continue;
        }
        uint8_t t[11];
        memcpy(t, lambda, sizeof t);
        const uint8_t coef = gf_div(d, b);
        for (int i = 0; i + m < 11; i++) lambda[i + m] ^= gf_mul(coef, prev[i]);
        if (2 * L <= n) {
            L = n + 1 - L;
            memcpy(prev, t, sizeof prev);
            b = d;
            m = 1;
        } else {
            m++;
        }
    }
    if (L > 5) return -1;

    // Ω(x) = S(x) Λ(x) mod x^10
    uint8_t omega[10] = { 0 };
    for (int i = 0; i < 10; i++) {
        for (int j = 0; j <= i && j <= L; j++) omega[i] ^= gf_mul(lambda[j], syndrome[i - j]);
    }

    // Chien search over the 120 used positions; Forney for the values.
    int found = 0;
    for (int i = 0; i < 120; i++) {
        const int power = 119 - i;                  // X = α^power
        const int inverse = (255 - power) % 255;    // X^-1
        uint8_t value = 0;
        for (int k = 0; k <= L; k++) value ^= gf_mul(lambda[k], gf_exp[(inverse * k) % 255]);
        if (value) continue;

        uint8_t num = 0, den = 0;
        for (int k = 0; k < 10; k++) num ^= gf_mul(omega[k], gf_exp[(inverse * k) % 255]);
        for (int k = 1; k <= L; k += 2) den ^= gf_mul(lambda[k], gf_exp[(inverse * (k - 1)) % 255]);
        if (den == 0) return -1;
        // First consecutive root α^0: e = X · Ω(X^-1) / Λ'(X^-1)
        c[i] ^= gf_mul(gf_exp[power], gf_div(num, den));
        found++;
    }
    return found == L ? found : -1;
}

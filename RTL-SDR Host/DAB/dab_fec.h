//
//  dab_fec.h
//  RTL-SDR Host
//
//  Forward error correction for DAB (EN 300 401) and DAB+ (TS 102 563):
//
//    - Soft-decision Viterbi decoder for the mother code: constraint
//      length 7, rate 1/4, generators 133, 171, 145, 133 (octal), with
//      6 tail bits that return the encoder to state 0.
//    - Reed-Solomon RS(120, 110, t = 5) over GF(2^8), field polynomial
//      x^8 + x^4 + x^3 + x^2 + 1, generator roots α^0 … α^9, shortened
//      from RS(255, 245).
//
//  Plain C because these inner loops run millions of times a second and
//  Swift loops are slow in debug builds.
//

#ifndef DAB_FEC_H
#define DAB_FEC_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Decodes `bits` information bits from 4 × (bits + 6) soft values in
/// mother-code order. A soft value is > 0 for a likely 0 bit, < 0 for a
/// likely 1 and 0 for unknown (punctured). Writes one bit (0 or 1) per byte
/// to `out`. `work` must hold dab_viterbi_work_size(bits) bytes.
void dab_viterbi(const int8_t *soft, size_t bits, uint8_t *out, void *work);
size_t dab_viterbi_work_size(size_t bits);

/// Corrects one RS(120, 110) codeword in place; byte 0 is the first data
/// byte, bytes 110 … 119 the parity. Returns the number of corrected bytes,
/// or -1 if the codeword has more errors than it can correct.
int dab_rs_decode(uint8_t codeword[120]);

/// Computes the 10 parity bytes for 110 data bytes (for tests).
void dab_rs_encode(const uint8_t data[110], uint8_t parity[10]);

#ifdef __cplusplus
}
#endif

#endif /* DAB_FEC_H */

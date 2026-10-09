/* Link against ConvertLIT's existing des.c (include directory: lib/des).
 * These are LIT-specific MS-DES outputs, matching Calibre's msdes implementation
 * (v9.14.0 src/calibre/utils/msdes). Standard DES is a different algorithm here.
 * No reference cipher or obsolete table source is required by this test.
 */
#include "d3des.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void require(int condition, const char *message) {
    if (!condition) { fprintf(stderr, "%s\n", message); exit(1); }
}

static void check(unsigned char key[8], unsigned char plain[8],
                  const unsigned char *expected) {
    unsigned char cipher[8], recovered[8], parity[8];
    unsigned char guarded[10] = {0xa5, 0, 0, 0, 0, 0, 0, 0, 0, 0x5a};
    unsigned long encryption_key[32];

    deskey(key, EN0);
    des(plain, cipher);
    if (expected) require(!memcmp(cipher, expected, 8), "legacy LIT ciphertext changed");
    cpkey(encryption_key);

    memcpy(guarded + 1, plain, 8);
    des(guarded + 1, guarded + 1);
    require(!memcmp(guarded + 1, cipher, 8), "in-place encryption changed ciphertext");
    require(guarded[0] == 0xa5 && guarded[9] == 0x5a, "encryption wrote outside the block");

    for (unsigned i = 0; i < 8; ++i) parity[i] = key[i] ^ 1;
    deskey(parity, EN0);
    des(plain, recovered);
    require(!memcmp(recovered, cipher, 8), "key parity bits changed ciphertext");

    deskey(key, DE1);
    des(cipher, recovered);
    require(!memcmp(recovered, plain, 8), "decryption did not recover plaintext");
    des(guarded + 1, guarded + 1);
    require(!memcmp(guarded + 1, plain, 8), "in-place decryption did not recover plaintext");
    require(guarded[0] == 0xa5 && guarded[9] == 0x5a, "decryption wrote outside the block");

    /* Changing to decryption must not invalidate a saved encryption schedule. */
    usekey(encryption_key);
    des(plain, recovered);
    require(!memcmp(recovered, cipher, 8), "saved encryption key reload changed ciphertext");
}

int main(void) {
    struct {
        unsigned char key[8], plain[8], cipher[8];
    } vectors[] = {
        {{0}, {0}, {0x9f,0xab,0x9a,0x5b,0x42,0x84,0x77,0xf2}},
        {{1,1,1,1,1,1,1,1}, {0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff},
         {0x36,0xf3,0x64,0x7d,0x18,0x9c,0x21,0xc5}},
        {{0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff}, {0},
         {0xc9,0x0c,0x9b,0x82,0xe7,0x63,0xde,0x3a}},
        {{0x13,0x34,0x57,0x79,0x9b,0xbc,0xdf,0xf1},
         {0x01,0x23,0x45,0x67,0x89,0xab,0xcd,0xef},
         {0xb9,0x5a,0x0c,0x90,0x72,0x20,0x70,0x39}}
    };
    for (unsigned i = 0; i < sizeof(vectors) / sizeof(vectors[0]); ++i)
        check(vectors[i].key, vectors[i].plain, vectors[i].cipher);

    uint32_t state = 0x6c697431;
    for (unsigned i = 0; i < 4096; ++i) {
        unsigned char key[8], plain[8];
        for (unsigned j = 0; j < 16; ++j) {
            state ^= state << 13; state ^= state >> 17; state ^= state << 5;
            if (j < 8) key[j] = (unsigned char)state;
            else plain[j - 8] = (unsigned char)state;
        }
        check(key, plain, NULL);
    }
    puts("PASS: legacy LIT vectors and 4096 block round trips, in-place bounds, parity, key reload");
    return 0;
}

/* OCE regression for CVE-2026-95692; no matching upstream test in 3.5.9.
 * Reject nonce lengths before a caller supplies a short IV buffer.
 */
#include <stdio.h>
#include <openssl/core_names.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/params.h>
#include <openssl/proverr.h>

int main(void)
{
    const char *names[] = {"AES-128-GCM-SIV", "AES-256-GCM-SIV"};
    size_t lengths[] = {0, 1, 11, 12, 13, 16};
    size_t n, l;
    int enc, api;

    for (n = 0; n < sizeof(names) / sizeof(names[0]); n++) {
        EVP_CIPHER *cipher = EVP_CIPHER_fetch(NULL, names[n], NULL);
        if (cipher == NULL)
            return 1;
        for (enc = 0; enc <= 1; enc++) {
            for (api = 0; api <= 1; api++) {
                for (l = 0; l < sizeof(lengths) / sizeof(lengths[0]); l++) {
                    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
                    size_t length = lengths[l];
                    OSSL_PARAM params[] = {
                        OSSL_PARAM_END, OSSL_PARAM_END
                    };
                    int result, valid = length == 12;
                    unsigned long error;
                    if (ctx == NULL ||
                        !EVP_CipherInit_ex2(ctx, cipher, NULL, NULL, enc, NULL))
                        return 1;
                    params[0] = OSSL_PARAM_construct_size_t(
                        OSSL_CIPHER_PARAM_AEAD_IVLEN, &length);
                    ERR_clear_error();
                    result = api
                        ? EVP_CIPHER_CTX_set_params(ctx, params)
                        : EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_IVLEN,
                                              (int)length, NULL);
                    error = ERR_peek_last_error();
                    EVP_CIPHER_CTX_free(ctx);
                    if ((result > 0) != valid ||
                        (!valid && ERR_GET_REASON(error) !=
                                       PROV_R_INVALID_IV_LENGTH)) {
                        fprintf(stderr,
                                "%s enc=%d api=%d IV=%zu result=%d error=%lu\n",
                                names[n], enc, api, length, result, error);
                        EVP_CIPHER_free(cipher);
                        return 1;
                    }
                }
            }
        }
        EVP_CIPHER_free(cipher);
    }
    puts("PASS: AES-GCM-SIV IV lengths 0,1,11,13,16 rejected; 12 accepted");
    return 0;
}

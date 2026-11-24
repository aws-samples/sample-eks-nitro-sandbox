#!/bin/sh
set -eu

out_dir=/out
source_dir=/build/openssl/source
expected_version=3.5.9-1~deb13u1+oce1
arch=$(dpkg --print-architecture)

test "$(cat "$out_dir/debian-version")" = 3.5.9-1~deb13u1
test "$(cat "$out_dir/package-version")" = "$expected_version"
diff -u - "$out_dir/runtime-packages.list" <<EOF
libssl3t64_${expected_version}_${arch}.deb
openssl_${expected_version}_${arch}.deb
openssl-provider-legacy_${expected_version}_${arch}.deb
EOF
diff -u - "$out_dir/build-packages.list" <<EOF
libssl-dev_${expected_version}_${arch}.deb
EOF
cd "$out_dir"
sha256sum --check --strict packages.sha256
for package in libssl3t64 openssl openssl-provider-legacy libssl-dev; do
  deb="${package}_${expected_version}_${arch}.deb"
  test "$(dpkg-deb --field "$deb" Package)" = "$package"
  test "$(dpkg-deb --field "$deb" Version)" = "$expected_version"
  test "$(dpkg-deb --field "$deb" Architecture)" = "$arch"
done

cd "$source_dir"
test "$(grep -c 'ADD_TEST(test_aes_gcm_siv_' test/evp_extra_test.c)" -eq 6
grep -Fq 'if (key != NULL || iv != NULL || ctx->used_enc || ctx->used_dec)' \
  providers/implementations/ciphers/cipher_aes_gcm_siv.c
grep -Fq 'if (len == 0)' \
  providers/implementations/ciphers/cipher_aes_gcm_siv_hw.c
grep -Fq 'static int test_aes_gcm_siv_zero_length_aad(void)' \
  test/evp_extra_test.c

# The package build compiles tests but skips Debian's full suite. Run the
# upstream recipe here with networking disabled by the Dockerfile stage.
make -C build_shared test TESTS=test_evp_extra

#!/bin/sh
set -eu

out_dir=/out
source_dir=/build/openssl/source
expected_version=3.5.9-1~deb13u1+oce3
asset_dir=/tmp/openssl
metadata_sha256=c54110fa43dafa9542779264036f2864a0b828551564d2400b5e22782b57e8da
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
sha256sum --check --strict source.sha256
cmp "$asset_dir/source.json" "$out_dir/source.json"
python3 "$asset_dir/security_assets.py" check-assets --assets "$asset_dir" \
  --expected-metadata-sha256 "$metadata_sha256"
for package in libssl3t64 openssl openssl-provider-legacy libssl-dev; do
  deb="${package}_${expected_version}_${arch}.deb"
  test "$(dpkg-deb --field "$deb" Package)" = "$package"
  test "$(dpkg-deb --field "$deb" Version)" = "$expected_version"
  test "$(dpkg-deb --field "$deb" Architecture)" = "$arch"
done

cd "$source_dir"
python3 "$asset_dir/security_assets.py" check-patched-source --assets "$asset_dir" \
  --source "$source_dir" --expected-metadata-sha256 "$metadata_sha256"
test "$(grep -c 'ADD_TEST(test_aes_gcm_siv_' test/evp_extra_test.c)" -eq 6
grep -Fq 'if (key != NULL || iv != NULL || ctx->used_enc || ctx->used_dec)' \
  providers/implementations/ciphers/cipher_aes_gcm_siv.c
grep -Fq 'if (len == 0)' \
  providers/implementations/ciphers/cipher_aes_gcm_siv_hw.c
grep -Fq 'static int test_aes_gcm_siv_zero_length_aad(void)' \
  test/evp_extra_test.c
grep -Fq 'if (BN_cmp(order, BN_value_one()) <= 0)' crypto/ec/ec_key.c
grep -Fq 'static int keygen_invalid_order_test(void)' test/ectest.c
grep -Fq 'ADD_TEST(keygen_invalid_order_test)' test/ectest.c
grep -Fq 'ADD_ALL_TESTS(test_stream_gc, 3)' test/quicapitest.c
grep -Fq 'if (iv_len != sizeof(ctx->nonce))' \
  providers/implementations/ciphers/cipher_aes_gcm_siv.c

# The package build compiles tests but skips Debian's full suite. Run the
# upstream recipe here with networking disabled by the Dockerfile stage.
test_recipes=$(python3 "$asset_dir/security_assets.py" test-recipes \
  --assets "$asset_dir" --expected-metadata-sha256 "$metadata_sha256")
make -C build_shared test TESTS="$test_recipes"

# Exercise the newly built shared library, not the base image's installed one.
cc -Ibuild_shared/include -Iinclude "$asset_dir/iv_length_regression.c" \
  -Lbuild_shared -Wl,-rpath,"$source_dir/build_shared" -lcrypto \
  -o /tmp/openssl-iv-length-regression
LD_LIBRARY_PATH="$source_dir/build_shared" /tmp/openssl-iv-length-regression

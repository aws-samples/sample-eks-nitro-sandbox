#!/bin/sh
set -eu
version=1:2.56.1-1+oce1
file_version=2.56.1-1+oce1
case "${1:-}" in
    --packages)
        test "$#" = 2
        cd "$2"
        arch=$(dpkg --print-architecture)
        printf '%s\n' "git_${file_version}_${arch}.deb" "git-man_${file_version}_all.deb" |
            diff -u - runtime-packages.list
        checksum_files=$(mktemp)
        trap 'rm -f "$checksum_files"' EXIT HUP INT TERM
        awk '{print $2}' packages.sha256 | sed 's#^\./##' | LC_ALL=C sort >"$checksum_files"
        LC_ALL=C sort runtime-packages.list | diff -u - "$checksum_files"
        find . -maxdepth 1 -type f -name '*.deb' -print | sed 's#^\./##' | LC_ALL=C sort |
            diff -u "$checksum_files" -
        sha256sum --check --strict packages.sha256
        for package in git git-man; do
            package_arch=$arch
            test "$package" != git-man || package_arch=all
            deb="${package}_${file_version}_${package_arch}.deb"
            test "$(dpkg-deb --field "$deb" Package)" = "$package"
            test "$(dpkg-deb --field "$deb" Version)" = "$version"
            test "$(dpkg-deb --field "$deb" Architecture)" = "$package_arch"
        done ;;
    --runtime)
        test "$#" = 1
        for package in git git-man; do
            test "$(dpkg-query -W -f='${db:Status-Status}' "$package")" = installed
            test "$(dpkg-query -W -f='${Version}' "$package")" = "$version"
        done
        test "$(git --version)" = 'git version 2.56.1'
        test -x "$(git --exec-path)/git-remote-https"
        ssh -V
        work=$(mktemp -d)
        trap 'rm -rf "$work"' EXIT HUP INT TERM
        git -c init.defaultBranch=main init "$work/source"
        printf '%s\n' 'runtime transport check' >"$work/source/check"
        git -C "$work/source" add check
        git -C "$work/source" -c user.name=Runtime -c user.email=runtime@example.invalid \
            commit -m check
        git clone --no-local "$work/source" "$work/local"
        cmp "$work/source/check" "$work/local/check"
        git -C "$work/local" fsck --full
        # Exercise Git's SSH transport without relying on an external SSH host.
        printf '#!/bin/sh\nprintf "called\\n" >"%s/ssh-called"\nexit 42\n' "$work" >"$work/ssh"
        chmod +x "$work/ssh"
        if GIT_SSH_COMMAND="$work/ssh" GIT_SSH_VARIANT=ssh \
            git ls-remote ssh://example.invalid/repository; then exit 1; fi
        test -s "$work/ssh-called"
        git clone --depth=1 https://github.com/octocat/Hello-World.git "$work/https"
        git -C "$work/https" fsck --full ;;
    *) echo "Usage: verify.sh --packages DIR | --runtime" >&2; exit 2 ;;
esac

# The Nitro Sandbox runtime for the aws-k8s-1.36-nitro-sandbox variant. The files are
# prebuilt releases: the builder verified each one against packages/sources.lock before the
# build, and buildsys checks the SHA-512 values in Cargo.toml again.
%global debug_package %{nil}
%global runtime_version 0.1.4274.0
%global firecracker_version 1.18.0

Name: %{_cross_os}nitro-sandbox
Version: %{runtime_version}
Release: 1%{?dist}
Summary: Nitro Sandbox runtime, Firecracker and the guest image
License: Apache-2.0 AND LicenseRef-AWS-IP-License
URL: https://docs.aws.amazon.com/eks/latest/userguide/sandboxing.html
AutoReqProv: no

Source0: nitro-sandboxes-runtime.tar.gz
Source1: firecracker-v%{firecracker_version}-x86_64.tgz
Source2: nitro-sandbox-guest.eif
Source3: nitro-sandbox-guest-disk.img
Source10: nitro-sandbox.toml
Source11: 50-nitro-sandbox.toml
Source12: cri-proxy.service
Source13: 50-nitro-sandbox-cri-proxy.conf
Source14: 00-nitro-sandbox-eni-unmanaged.network
Source15: nitro-sandbox-tmpfiles.conf
Source16: nitro-sandbox-modules-load.conf

ExclusiveArch: x86_64
Requires: %{_cross_os}glibc
Requires: %{_cross_os}libgcc
Requires: %{_cross_os}containerd

%description
%{summary}.

%prep
%setup -q -c -T
tar -xzf %{S:0} containerd-shim-nitro-sandbox-v2 nitro-sandbox-shim-logger-wrapper LICENSE ATTRIBUTION
tar -xzf %{S:1} \
  release-v%{firecracker_version}-x86_64/firecracker-v%{firecracker_version}-x86_64 \
  release-v%{firecracker_version}-x86_64/jailer-v%{firecracker_version}-x86_64 \
  release-v%{firecracker_version}-x86_64/LICENSE \
  release-v%{firecracker_version}-x86_64/NOTICE
mv release-v%{firecracker_version}-x86_64/LICENSE LICENSE-firecracker
mv release-v%{firecracker_version}-x86_64/NOTICE NOTICE-firecracker

%build
# The build must not run with the template value: scripts/builder/30-overlay.sh writes the
# sandbox slot count into nitro-sandbox.toml first.
grep -Eq '^pcie_slots += [1-9][0-9]*$' %{S:10}
! grep -q '@' %{S:10}

%install
install -d %{buildroot}%{_cross_bindir}
install -p -m 0755 containerd-shim-nitro-sandbox-v2 %{buildroot}%{_cross_bindir}/containerd-shim-nitro-sandbox-v2
install -p -m 0755 nitro-sandbox-shim-logger-wrapper %{buildroot}%{_cross_bindir}/nitro-sandbox-shim-logger-wrapper
install -p -m 0755 release-v%{firecracker_version}-x86_64/firecracker-v%{firecracker_version}-x86_64 %{buildroot}%{_cross_bindir}/firecracker
install -p -m 0755 release-v%{firecracker_version}-x86_64/jailer-v%{firecracker_version}-x86_64 %{buildroot}%{_cross_bindir}/jailer

install -d %{buildroot}%{_cross_datadir}/nitro-sandbox
install -p -m 0644 %{S:2} %{buildroot}%{_cross_datadir}/nitro-sandbox/latest.eif
install -p -m 0644 %{S:3} %{buildroot}%{_cross_datadir}/nitro-sandbox/latest-disk.img
ln -s latest-disk.img %{buildroot}%{_cross_datadir}/nitro-sandbox/rootfs.ext4

# /etc is a tmpfs on Bottlerocket: tmpfiles copies these from the factory folder at boot.
install -d %{buildroot}%{_cross_factorydir}%{_cross_sysconfdir}/containerd/config.d
install -p -m 0644 %{S:10} %{buildroot}%{_cross_factorydir}%{_cross_sysconfdir}/containerd/nitro-sandbox.toml
install -p -m 0644 %{S:11} %{buildroot}%{_cross_factorydir}%{_cross_sysconfdir}/containerd/config.d/50-nitro-sandbox.toml

install -d %{buildroot}%{_cross_unitdir}/kubelet.service.d
install -p -m 0644 %{S:12} %{buildroot}%{_cross_unitdir}/cri-proxy.service
install -p -m 0644 %{S:13} %{buildroot}%{_cross_unitdir}/kubelet.service.d/50-nitro-sandbox-cri-proxy.conf

install -d %{buildroot}%{_cross_libdir}/systemd/network
install -p -m 0644 %{S:14} %{buildroot}%{_cross_libdir}/systemd/network/00-nitro-sandbox-eni-unmanaged.network

install -d %{buildroot}%{_cross_tmpfilesdir}
install -p -m 0644 %{S:15} %{buildroot}%{_cross_tmpfilesdir}/nitro-sandbox.conf

install -d %{buildroot}%{_cross_libdir}/modules-load.d
install -p -m 0644 %{S:16} %{buildroot}%{_cross_libdir}/modules-load.d/nitro-sandbox.conf

%files
%license LICENSE ATTRIBUTION LICENSE-firecracker NOTICE-firecracker
%{_cross_bindir}/containerd-shim-nitro-sandbox-v2
%{_cross_bindir}/nitro-sandbox-shim-logger-wrapper
%{_cross_bindir}/firecracker
%{_cross_bindir}/jailer
%dir %{_cross_datadir}/nitro-sandbox
%{_cross_datadir}/nitro-sandbox/latest.eif
%{_cross_datadir}/nitro-sandbox/latest-disk.img
%{_cross_datadir}/nitro-sandbox/rootfs.ext4
%{_cross_factorydir}%{_cross_sysconfdir}/containerd/nitro-sandbox.toml
%{_cross_factorydir}%{_cross_sysconfdir}/containerd/config.d/50-nitro-sandbox.toml
%{_cross_unitdir}/cri-proxy.service
%{_cross_unitdir}/kubelet.service.d/50-nitro-sandbox-cri-proxy.conf
%{_cross_libdir}/systemd/network/00-nitro-sandbox-eni-unmanaged.network
%{_cross_tmpfilesdir}/nitro-sandbox.conf
%{_cross_libdir}/modules-load.d/nitro-sandbox.conf

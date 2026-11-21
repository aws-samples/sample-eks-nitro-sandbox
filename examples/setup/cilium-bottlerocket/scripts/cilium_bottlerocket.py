#!/usr/bin/env python3
"""The checks and renderers that setup.sh, test.sh and clean.sh call.

    python3 scripts/cilium_bottlerocket.py <subcommand> [arguments]

Each subcommand is one check with one stable tag (check-containerd-dump is E_CONTAINERD_DUMP).
Exit 0 accept, 1 reject ("ERROR: E_<TAG>: ..."), 2 could not check ("ERROR: E_<TAG>_UNKNOWN: ...").
A check reads its input from a file argument or stdin, so the offline tests can give it a
fixture; the live input comes from the script that calls it. scripts/common.sh exports the
settings and the run state paths that the subcommands read.
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))

import cb_aws  # noqa: E402
import cb_checks  # noqa: E402
import cb_inventory  # noqa: E402
import cb_render  # noqa: E402
from cb_base import main_wrapper  # noqa: E402


def parser():
    p = argparse.ArgumentParser(prog="cilium_bottlerocket.py")
    sub = p.add_subparsers(dest="command", required=True)

    def add(name, func, *args):
        s = sub.add_parser(name)
        for spec in args:
            flags, kw = spec
            s.add_argument(*flags, **kw)
        s.set_defaults(func=func)
        return s

    opt_file = (["file"], {"nargs": "?"})
    group = (["group"], {"choices": ["system", "sandbox"]})
    add("check-config", cb_render.cmd_check_config)
    add("check-cilium-values", cb_render.cmd_check_cilium_values, opt_file)
    add("check-manifests", cb_render.cmd_check_manifests, (["dir"], {"nargs": "?"}))
    add("render-cluster", cb_render.cmd_render_cluster)
    add("render-pod-identity", cb_render.cmd_render_pod_identity)
    add("render-nodegroup", cb_render.cmd_render_nodegroup, group)
    add("render-probe", cb_render.cmd_render_probe, (["--name"], {"required": True}), (["--node"], {"required": True}))
    add("render-filler", cb_render.cmd_render_filler, (["--name"], {"required": True}), (["--node"], {"required": True}))
    add("launch-template", cb_render.cmd_launch_template, group)
    add("check-user-data", cb_render.cmd_check_user_data, group, opt_file)
    add("runtimeclass", cb_render.cmd_runtimeclass)
    add("check-runtimeclass", cb_render.cmd_check_runtimeclass, opt_file)
    add("preflight-daemonset", cb_render.cmd_preflight_daemonset, opt_file)
    add("check-operator-role", cb_render.cmd_check_operator_role)
    add("resolve-system-ami", cb_aws.cmd_resolve_system_ami)
    add("check-system-ami", cb_aws.cmd_check_system_ami, opt_file, (["--ami"], {}))
    add("check-sandbox-ami", cb_aws.cmd_check_sandbox_ami, (["--ami"], {}), (["--images"], {}),
        (["--uefi"], {}), (["--snapshots"], {}), (["--reuse"], {"action": "store_true"}))
    add("builder-gone", cb_aws.cmd_builder_gone)
    add("quota", cb_aws.cmd_quota)
    add("check-names", cb_aws.cmd_check_names)
    add("recheck", cb_aws.cmd_recheck, (["kind"], {"choices": sorted(cb_aws.GONE)}), (["ident"], {}))
    add("check-os-image", cb_checks.cmd_check_os_image, group, opt_file)
    add("check-btf", cb_checks.cmd_check_btf, opt_file)
    add("check-mempool", cb_checks.cmd_check_mempool, (["--cmdline"], {"required": True}),
        (["--kernel-log"], {"required": True}))
    add("check-runtime-endpoint", cb_checks.cmd_check_runtime_endpoint, opt_file)
    add("check-containerd-dump", cb_checks.cmd_check_containerd_dump, opt_file)
    add("check-allocatable", cb_checks.cmd_check_allocatable, opt_file)
    add("check-density", cb_checks.cmd_check_density, (["--slots"], {"type": int}), (["--ami-tags"], {}),
        (["--launch-template"], {}), (["--node"], {}), (["--shim-toml"], {}))
    add("check-selinux-mode", cb_checks.cmd_check_selinux_mode, opt_file)
    add("selinux-audit", cb_checks.cmd_selinux_audit, (["avc_file"], {}), (["journal_file"], {}))
    add("check-selinux-domains", cb_checks.cmd_check_selinux_domains, opt_file)
    add("check-networkd", cb_checks.cmd_check_networkd, opt_file)
    add("check-eni-stable", cb_checks.cmd_check_eni_stable, (["--before"], {"required": True}),
        (["--after"], {"required": True}), (["--ciliumnode"], {"required": True}))
    add("check-dm-verity", cb_checks.cmd_check_dm_verity, opt_file)
    add("check-network-isolated", cb_checks.cmd_check_network_isolated, opt_file)
    add("pod-in-eni", cb_checks.cmd_pod_in_eni, (["pod_ip"], {}), opt_file)
    add("kpr-status", cb_checks.cmd_kpr_status, opt_file, (["--config"], {"required": True}))
    add("audit-tags", cb_inventory.cmd_audit_tags, (["--after-build"], {"action": "store_true"}))
    add("tag-sweep", cb_inventory.cmd_tag_sweep)
    add("owned", cb_inventory.cmd_owned)
    return p


def main():
    args = parser().parse_args()
    return main_wrapper(args.command, args.func, args)


if __name__ == "__main__":
    sys.exit(main())

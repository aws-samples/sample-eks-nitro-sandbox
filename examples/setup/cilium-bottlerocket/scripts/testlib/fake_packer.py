#!/usr/bin/env python3
"""A small fake of Packer 1.16.2 with the Amazon plugin 1.8.4, for this sample's offline tests only.

scripts/testlib/fixture_packer_release.py puts a launcher for this file into a fixture Packer
release zip as `packer`, so the real download, signature and checksum checks of scripts/10-build-ami-packer.sh run and
the binary they accept is the one that runs. The launcher bakes in the paths of the world state,
the call log and this folder, because the wrapper runs Packer under `env -i` and drops FAKE_*
variables. For the same reason every test case is set in the world state, never in the
environment:

  state["packer"] = {
    "version": "1.16.2",            what `packer version` prints after "Packer v"
    "manifest": "one-ami",          one-ami | two-amis | zero | malformed | wrong-run-id | none
    "snapshots": 2,                 snapshots of the registered AMI (2 is right; 3 = builder root kept)
    "untagged_snapshot": false,     one snapshot without the owner tags
    "leftovers": [],                builder parts left after the build: instance, volume, eni
    "hang": "",                     "" | "build" | "stage:<n>": wait for SIGINT at that point
    "build_rc": 0,                  exit code of `packer build` after a normal run
    "validate_rc": 0,
    "registration": {}              overrides of the registered image's fields (BootMode, UefiData...)
  }

`build` records argv and the NAMES of the variables in its environment (never a value) in the
call log, refuses each forbidden flag, reads -var-file, launches a builder instance with its
volumes in the world state, then runs the `inline` commands of each provisioner "shell-local"
block of the real template in order, with that block's `env` map and `build.ID` set to the
builder. On success it registers the AMI with its snapshots, terminates the builder and writes
the manifest. On a failed stage or SIGINT it terminates the builder (Packer's -on-error=cleanup)
and exits 1. It never contacts AWS.
"""
import glob
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import uuid

TESTLIB = os.environ.get("FAKE_TESTLIB") or os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TESTLIB)
import fakelib  # noqa: E402
from fakelib import taglist, tagmap  # noqa: E402

FORBIDDEN = ("-debug", "-force", "-on-error=ask", "-on-error=abort", "-on-error=run-cleanup-provisioner",
             "-machine-readable", "-var", "-only", "-except")
MANAGED_BY = "cilium-bottlerocket-sample"


def hcl_files(path):
    return sorted(glob.glob(os.path.join(path, "*.pkr.hcl"))) if os.path.isdir(path) else [path]


def blocks(text, head):
    """The bodies of every block whose header matches the regex head, brace-matched."""
    out = []
    for m in re.finditer(head + r"\s*\{", text):
        depth, i = 1, m.end()
        while depth and i < len(text):
            ch = text[i]
            if ch == '"':
                i += 1
                while i < len(text) and text[i] != '"':
                    i += 2 if text[i] == "\\" else 1
            elif ch == "#" or text.startswith("//", i):
                i = text.find("\n", i)
                i = len(text) if i < 0 else i
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
            i += 1
        out.append(text[m.end():i - 1])
    return out


STR = r'"((?:[^"\\]|\\.)*)"'


def unquote(s):
    return bytes(s, "utf-8").decode("unicode_escape")


def interp(s, vars_, build):
    def rep(m):
        expr = m.group(1).strip()
        if expr.startswith("var."):
            return str(vars_.get(expr[4:], ""))
        if expr.startswith("build."):
            return str(build.get(expr[6:], ""))
        return m.group(0)
    return re.sub(r"\$\{([^}]+)\}", rep, s)


def expr_value(expr, vars_, build):
    expr = expr.strip().rstrip(",")
    m = re.fullmatch(STR, expr)
    if m:
        return interp(unquote(m.group(1)), vars_, build)
    if expr.startswith("var."):
        return str(vars_.get(expr[4:], ""))
    if expr.startswith("build."):
        return str(build.get(expr[6:], ""))
    return expr


def provisioners(dirpath, vars_, build):
    out = []
    for f in hcl_files(dirpath):
        text = open(f).read()
        for body in blocks(text, r'provisioner\s+"shell-local"'):
            mi = re.search(r"\binline\s*=\s*\[(.*?)\]", body, re.S)
            inline = [interp(unquote(s), vars_, build) for s in re.findall(STR, mi.group(1))] if mi else []
            env = {}
            for eb in blocks(body, r"\benv\s*="):
                for line in re.split(r"[\n,]", eb):
                    mm = re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+?)\s*$", line)
                    if mm:
                        env[mm.group(1)] = expr_value(mm.group(2), vars_, build)
            me = re.search(r"\benvironment_vars\s*=\s*\[(.*?)\]", body, re.S)
            if me:
                for s in re.findall(STR, me.group(1)):
                    k, _, v = interp(unquote(s), vars_, build).partition("=")
                    env[k] = v
            out.append({"inline": inline, "env": env})
    return out


def manifest_output(dirpath, vars_):
    for f in hcl_files(dirpath):
        for body in blocks(open(f).read(), r'post-processor\s+"manifest"'):
            m = re.search(r"\boutput\s*=\s*(.+)", body)
            if m:
                return expr_value(m.group(1), vars_, {})
    return vars_.get("manifest_path", "")


class Builder:
    """The builder and the artifacts, tagged as packer/bottlerocket.pkr.hcl tags them:
    run_tags (Name = build_name, ManagedBy, RunId) on the instance, its volumes and its network
    interface (the plugin's RunInstances tag specification), and
    image_tags (pin_tags, Name = ami_name, ManagedBy, RunId, SandboxSlots) on the AMI and both
    snapshots. cfg["image_tags_override"] changes image tags, cfg["builder_overrides"] adds
    fields to the instance (for example KeyName or PublicIpAddress), cfg["eni_tags_override"]
    changes the tags of its network interface (a value None removes that tag)."""

    def __init__(self, vars_, cfg):
        self.vars, self.cfg = vars_, cfg
        self.run_id = str(vars_.get("run_id", ""))
        self.region = str(vars_.get("region", "us-west-2"))
        managed = str(vars_.get("managed_by", MANAGED_BY))
        self.tags = {"Name": str(vars_.get("build_name", "")), "ManagedBy": managed, "RunId": self.run_id}
        pins = vars_.get("pin_tags") or {}
        self.image_tags = dict(pins, Name=str(vars_.get("ami_name", "")), ManagedBy=managed, RunId=self.run_id,
                               SandboxSlots=str(vars_.get("sandbox_slots", "")))
        self.image_tags.update(cfg.get("image_tags_override") or {})
        self.iid = None
        self.vols = {}

    def launch(self):
        with fakelib.world() as (state, _):
            ec2 = state.setdefault("ec2", {})
            n = len(ec2.setdefault("instances", [])) + 1
            self.iid = f"i-0fb{n:014d}"
            subnet = str(next((v for k, v in self.vars.items() if "subnet" in k), ""))
            sg = str(next((v for k, v in self.vars.items() if "security_group" in k), ""))
            vpc = next((s.get("VpcId") for s in ec2.get("subnets", []) if s.get("SubnetId") == subnet), None)
            prof = str(next((v for k, v in self.vars.items() if "instance_profile" in k), ""))
            vols = ec2.setdefault("volumes", [])
            bdm = []
            for j, dev in enumerate(("/dev/xvda", "/dev/xvdc", "/dev/xvdf", "/dev/xvdb")):
                vid = f"vol-0fb{n:06d}{j:08d}"
                self.vols[dev] = vid
                vols.append({"VolumeId": vid, "State": "in-use", "Size": 30, "VolumeType": "gp3",
                             "Attachment": {"InstanceId": self.iid, "Device": dev}, "DeleteOnTermination": True,
                             "Attachments": [{"InstanceId": self.iid, "Device": dev, "State": "attached"}],
                             "Tags": taglist(self.tags)})
                bdm.append({"DeviceName": dev, "Ebs": {"VolumeId": vid, "Status": "attached", "DeleteOnTermination": True}})
            # The primary network interface. The Amazon plugin puts run_tags on it in RunInstances
            # (tag specification "network-interface"); cfg["eni_tags_override"] changes its tags,
            # and a key set to None removes that tag.
            eni = f"eni-0fb{n:014d}"
            eni_tags = dict(self.tags, **(self.cfg.get("eni_tags_override") or {}))
            ec2.setdefault("network_interfaces", []).append({
                "NetworkInterfaceId": eni, "Status": "in-use", "SubnetId": subnet, "VpcId": vpc,
                "InterfaceType": "interface", "Groups": [{"GroupId": sg}] if sg else [],
                "Attachment": {"InstanceId": self.iid, "DeviceIndex": 0, "Status": "attached", "DeleteOnTermination": True},
                "TagSet": taglist({k: v for k, v in eni_tags.items() if v is not None})})
            inst = {"InstanceId": self.iid, "State": {"Name": "running"}, "SubnetId": subnet, "VpcId": vpc,
                    "NetworkInterfaces": [{"NetworkInterfaceId": eni,
                                           "Attachment": {"DeviceIndex": 0, "Status": "attached", "DeleteOnTermination": True}}],
                    "SecurityGroups": [{"GroupId": sg}] if sg else [], "BlockDeviceMappings": bdm,
                    "IamInstanceProfile": {"Arn": f"arn:aws:iam::{state.get('account', '')}:instance-profile/{prof}"},
                    "MetadataOptions": {"HttpTokens": "required", "HttpPutResponseHopLimit": 1, "HttpEndpoint": "enabled"},
                    "ImageId": str(self.vars.get("builder_ami_id", "")), "InstanceType": str(self.vars.get("instance_type", "")),
                    "Tags": taglist(self.tags), "Packer": True}
            inst.update(self.cfg.get("builder_overrides") or {})
            ec2["instances"].append(inst)
        fakelib.log_call("packer", "launch builder", [], {"instance": self.iid})
        return self.iid

    def cleanup(self, keep=()):
        with fakelib.world() as (state, _):
            ec2 = state.setdefault("ec2", {})
            for x in ec2.get("instances", []):
                if x["InstanceId"] == self.iid and "instance" not in keep:
                    x["State"] = {"Name": "terminated"}
            if "instance" not in keep:
                ec2["volumes"] = [v for v in ec2.get("volumes", [])
                                  if (v.get("Attachment") or {}).get("InstanceId") != self.iid
                                  or ("volume" in keep and v["Attachment"]["Device"] == "/dev/xvdc")]
                for v in ec2["volumes"]:
                    if (v.get("Attachment") or {}).get("InstanceId") == self.iid:
                        v["State"], v["Attachments"] = "available", []
                        v.pop("Attachment", None)
                # The interface goes with the instance (DeleteOnTermination), unless "eni" is
                # kept: then it stays detached and available, with its tags.
                enis = ec2.setdefault("network_interfaces", [])
                mine = [e for e in enis if (e.get("Attachment") or {}).get("InstanceId") == self.iid]
                for e in mine:
                    if "eni" in keep:
                        e["Status"] = "available"
                        e.pop("Attachment", None)
                    else:
                        enis.remove(e)
        fakelib.log_call("packer", "cleanup builder", [], {"instance": self.iid, "kept": list(keep)})

    def register(self):
        cfg = self.cfg
        with fakelib.world() as (state, _):
            ec2 = state.setdefault("ec2", {})
            n = len(ec2.setdefault("images", [])) + 1
            ami = f"ami-0fb{n:014d}"
            snaps = []
            # (AMI device, the launch volume it is made from): the OS image becomes the root.
            # A third snapshot is what an un-omitted builder root would add (#281 M2).
            plan = [("/dev/xvda", "/dev/xvdf"), ("/dev/xvdb", "/dev/xvdb"), ("/dev/xvdc", "/dev/xvda")]
            for j, (dev, src) in enumerate(plan[:max(0, int(cfg.get("snapshots", 2)))]):
                sid = f"snap-0fb{n:06d}{j:08d}"
                tags = {} if (cfg.get("untagged_snapshot") and j == 1) else dict(self.image_tags)
                ec2.setdefault("snapshots", []).append({"SnapshotId": sid, "State": "completed", "VolumeSize": 20,
                                                        "VolumeId": self.vols.get(src, ""), "Tags": taglist(tags)})
                snaps.append({"DeviceName": dev, "Ebs": {"SnapshotId": sid, "VolumeType": "gp3",
                                                         "DeleteOnTermination": True, "VolumeSize": 20,
                                                         "Encrypted": False}})
            img = {"ImageId": ami, "Name": str(self.vars.get("ami_name", "cilium-bottlerocket-fake")), "State": "available",
                   "Architecture": "x86_64", "VirtualizationType": "hvm", "EnaSupport": True,
                   "SriovNetSupport": "simple", "ImdsSupport": "v2.0", "BootMode": "uefi-preferred",
                   "RootDeviceName": "/dev/xvda", "RootDeviceType": "ebs", "BlockDeviceMappings": snaps,
                   "Public": False, "Tags": taglist(self.image_tags)}
            img.update(cfg.get("registration") or {})
            ec2["images"].append(img)
        return ami


def wait_for_sigint(builder, where):
    got = {"sig": False}

    def on_int(signum, frame):
        got["sig"] = True
    signal.signal(signal.SIGINT, on_int)
    signal.signal(signal.SIGTERM, on_int)
    fakelib.log_call("packer", "waiting for SIGINT", [], {"at": where})
    deadline = time.time() + 120
    while not got["sig"] and time.time() < deadline:
        time.sleep(0.05)
    fakelib.log_call("packer", "interrupted", [], {"at": where, "signal": got["sig"]})
    builder.cleanup()
    print("==> amazon-ebssurrogate.bottlerocket: Build was cancelled.", file=sys.stderr)
    return 1


def build(argv, cfg, state_account):
    bad = [a for a in argv if a in FORBIDDEN or a.split("=", 1)[0] in ("-var",)]
    if bad:
        print(f"FAKE packer: refused forbidden flag(s): {' '.join(bad)}", file=sys.stderr)
        return 1
    var_files = [a.split("=", 1)[1] for a in argv if a.startswith("-var-file=")]
    vars_ = {}
    for vf in var_files:
        vars_.update(json.load(open(vf)))
    target = argv[-1]
    b = Builder(vars_, cfg)
    if cfg.get("hang") == "build":
        b.launch()
        return wait_for_sigint(b, "build")
    iid = b.launch()
    info = {"ID": iid, "PackerRunUUID": str(uuid.UUID(int=1)), "name": "bottlerocket"}
    for n, prov in enumerate(provisioners(target, vars_, info), 1):
        if cfg.get("hang") == f"stage:{n}":
            return wait_for_sigint(b, f"stage:{n}")
        env = dict(os.environ, **prov["env"])
        for cmd in prov["inline"]:
            fakelib.log_call("packer", "shell-local", [cmd], {"stage": n, "env_names": sorted(prov["env"])})
            rc = subprocess.run(["/bin/sh", "-c", cmd], env=env).returncode
            if rc != 0:
                print(f"==> amazon-ebssurrogate.bottlerocket: Script exited with non-zero exit status: {rc}", file=sys.stderr)
                b.cleanup()
                return 1
    ami = b.register()
    b.cleanup(keep=tuple(cfg.get("leftovers") or ()))
    out = manifest_output(target, vars_)
    case = cfg.get("manifest", "one-ami")
    if out and case != "none":
        art = lambda a: {"name": "bottlerocket", "builder_type": "amazon-ebssurrogate", "build_time": 1,  # noqa: E731
                         "files": None, "artifact_id": f"{b.region}:{a}", "packer_run_uuid": info["PackerRunUUID"],
                         "custom_data": {"run_id": b.run_id if case != "wrong-run-id" else "otherrun"}}
        builds = {"one-ami": [art(ami)], "two-amis": [art(ami), art("ami-0fb99999999999999")], "zero": [],
                  "wrong-run-id": [art(ami)]}.get(case)
        os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
        with open(out, "w") as f:
            if case == "malformed":
                f.write('{"builds": [ {"artifact_id": ')
            else:
                json.dump({"builds": builds, "last_run_uuid": info["PackerRunUUID"]}, f, indent=2)
    print(f"==> Builds finished. The artifacts of successful builds are:\n--> amazon-ebssurrogate.bottlerocket: AMIs were created:\n{b.region}: {ami}")
    return int(cfg.get("build_rc", 0))


def main(argv):
    fakelib.require_state("packer")
    with open(fakelib.STATE_PATH) as f:
        state = json.load(f)
    cfg = state.get("packer") or {}
    pos = [a for a in argv if not a.startswith("-")]
    call = " ".join(pos[:2]) if pos[:1] == ["plugins"] else (pos[0] if pos else "")
    fakelib.log_call("packer", call, argv, {"env_names": sorted(os.environ)})
    code = fakelib.injected_failure("packer", call, argv)
    if code:
        print(f"Error: {code}: injected by the test", file=sys.stderr)
        return 1
    if call == "version":
        print(f"Packer v{os.environ.get('FAKE_PACKER_VERSION') or cfg.get('version', '1.16.2')}")
        return 0
    if call == "plugins install":
        src = argv[argv.index("--path") + 1] if "--path" in argv else None
        dest = os.path.join(os.environ.get("PACKER_PLUGIN_PATH", ""), "github.com", "hashicorp", "amazon")
        if not src or not os.environ.get("PACKER_PLUGIN_PATH"):
            print("FAKE packer: plugins install needs --path and PACKER_PLUGIN_PATH", file=sys.stderr)
            return 1
        os.makedirs(dest, exist_ok=True)
        target = os.path.join(dest, os.path.basename(src))
        shutil.copy(src, target)
        # Packer writes a <binary>_SHA256SUM file beside an installed plugin.
        import hashlib
        with open(target + "_SHA256SUM", "w") as f:
            f.write(hashlib.sha256(open(target, "rb").read()).hexdigest())
        print(f"Successfully installed plugin github.com/hashicorp/amazon from {src} to {dest}")
        return 0
    if call == "plugins installed":
        root = os.environ.get("PACKER_PLUGIN_PATH", "")
        for p in sorted(glob.glob(os.path.join(root, "**", "packer-plugin-*"), recursive=True)):
            print(p)
        return 0
    if call == "plugins required":
        for f in hcl_files(pos[2] if len(pos) > 2 else "."):
            m = re.search(r'source\s*=\s*"github.com/hashicorp/amazon"\s*,?\s*version\s*=\s*"([^"]+)"', open(f).read())
            if m:
                print(f"github.com/hashicorp/amazon {m.group(1)}")
        return 0
    if call == "init":
        return 0
    if call == "validate":
        return int(cfg.get("validate_rc", 0))
    if call == "build":
        return build(argv[1:], cfg, state.get("account", ""))
    print(f"FAKE packer: unexpected call not modelled by the test: {' '.join(argv)}", file=sys.stderr)
    return 97


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

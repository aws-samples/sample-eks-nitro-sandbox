#!/usr/bin/env python3
"""Render and check the launch specifications this sample hands to EC2.

Every instance the sample launches (the build host, the fresh verification instance, and the
managed node group's nodes through the launch template) must:
  * require IMDSv2 (HttpTokens=required) with a hop limit of 1, so a container on the host cannot
    reach the instance's credentials through the metadata service (a pod that needs AWS uses EKS
    Pod Identity);
  * run with Nitro Enclaves enabled;
  * carry ManagedBy=<RESOURCE_PREFIX> and RunId=<RUN_ID> on the instance AND its volumes.

  launch_spec.py render-instance --name N --image-id I --instance-type T --profile P \
      --security-group G --subnet S [--root-gb 120] TAGS
      prints the JSON for `aws ec2 run-instances --cli-input-json`
  launch_spec.py render-lt --name N --image-id I --instance-type T --user-data-file F TAGS
      prints the JSON for `aws ec2 create-launch-template --launch-template-data`
  launch_spec.py check-instance FILE TAGS | check-lt FILE TAGS
      exit 0 when the spec meets every rule above, 1 (one FAIL line per broken rule) otherwise
  TAGS = --owner-key K --owner-value V --run-key K2 --run-id R

The scripts render a spec, check it, and only then call EC2 with that same file, so the check
covers exactly what is sent.
"""
import argparse
import base64
import json
import sys

HOP_LIMIT = 1


def tags(a, name):
    return [{"Key": "Name", "Value": name}, {"Key": a.owner_key, "Value": a.owner_value}, {"Key": a.run_key, "Value": a.run_id}]


def common(a, name):
    return {
        "MetadataOptions": {"HttpTokens": "required", "HttpEndpoint": "enabled", "HttpPutResponseHopLimit": HOP_LIMIT},
        "EnclaveOptions": {"Enabled": True},
        "TagSpecifications": [{"ResourceType": rt, "Tags": tags(a, name)} for rt in ("instance", "volume")],
    }


def render_instance(a):
    spec = {"ImageId": a.image_id, "InstanceType": a.instance_type, "MinCount": 1, "MaxCount": 1,
            "IamInstanceProfile": {"Name": a.profile}, "SecurityGroupIds": [a.security_group], "SubnetId": a.subnet}
    if a.root_gb:
        spec["BlockDeviceMappings"] = [{"DeviceName": "/dev/sda1", "Ebs": {"VolumeSize": int(a.root_gb), "VolumeType": "gp3"}}]
    spec.update(common(a, a.name))
    return spec


def render_lt(a):
    with open(a.user_data_file, "rb") as f:
        ud = base64.b64encode(f.read()).decode()
    spec = {"ImageId": a.image_id, "InstanceType": a.instance_type, "UserData": ud}
    spec.update(common(a, a.name))
    return spec


def check(spec, a):
    bad = []
    md = spec.get("MetadataOptions") or {}
    if md.get("HttpTokens") != "required":
        bad.append(f"MetadataOptions.HttpTokens is {md.get('HttpTokens')!r}, must be 'required' (IMDSv2)")
    if md.get("HttpPutResponseHopLimit") != HOP_LIMIT:
        bad.append(f"MetadataOptions.HttpPutResponseHopLimit is {md.get('HttpPutResponseHopLimit')!r}, must be {HOP_LIMIT}")
    if md.get("HttpEndpoint", "enabled") != "enabled":
        bad.append("MetadataOptions.HttpEndpoint is disabled; SSM and the node bootstrap need IMDS")
    if (spec.get("EnclaveOptions") or {}).get("Enabled") is not True:
        bad.append("EnclaveOptions.Enabled is not true")
    by_type = {}
    for ts in spec.get("TagSpecifications") or []:
        by_type.setdefault(ts.get("ResourceType"), {}).update({t.get("Key"): t.get("Value") for t in ts.get("Tags") or []})
    for rt in ("instance", "volume"):
        t = by_type.get(rt)
        if t is None:
            bad.append(f"no TagSpecifications for ResourceType {rt}")
            continue
        for k, v in ((a.owner_key, a.owner_value), (a.run_key, a.run_id)):
            if t.get(k) != v:
                bad.append(f"{rt} tag {k} is {t.get(k)!r}, must be {v!r}")
    return bad


def main():
    p = argparse.ArgumentParser()
    p.add_argument("cmd", choices=["render-instance", "render-lt", "check-instance", "check-lt"])
    p.add_argument("file", nargs="?")
    for o in ("name", "image-id", "instance-type", "profile", "security-group", "subnet", "root-gb", "user-data-file"):
        p.add_argument("--" + o)
    for o in ("owner-key", "owner-value", "run-key", "run-id"):
        p.add_argument("--" + o, required=True)
    a = p.parse_args()
    if a.cmd == "render-instance":
        print(json.dumps(render_instance(a), indent=1))
        return 0
    if a.cmd == "render-lt":
        print(json.dumps(render_lt(a), indent=1))
        return 0
    try:
        with open(a.file) as f:
            spec = json.load(f)
    except (OSError, ValueError, TypeError) as e:
        print(f"FAIL: cannot read launch spec {a.file}: {e}", file=sys.stderr)
        return 1
    bad = check(spec, a)
    for b in bad:
        print(f"FAIL: {b}", file=sys.stderr)
    print(("LAUNCH SPEC REFUSED: " if bad else "LAUNCH SPEC OK: ") + str(a.file), file=sys.stderr if bad else sys.stdout)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Saved AWS CLI and Packer JSON in the shapes scripts/lib/packer_manifest.py reads, for the offline
tests only (scripts/test-packer-manifest.sh).

    fixture_aws_json.py good <dir>                 write the good documents of one fixture run
    fixture_aws_json.py mutate <src> <dst> <code>  copy a JSON document, run <code> on it as `d`

The good set is one run: run ID r1, the sample's ManagedBy, SandboxSlots 58, one AMI with two
snapshots made from the OS and data volumes, one builder with four volumes and one security group.
"""
import json
import os
import sys

RUN, MB, SLOTS = "r1", "cilium-bottlerocket-sample", "58"
AMI = "ami-0fb00000000000001"
SNAP_ROOT, SNAP_DATA = "snap-0fb00000000000001", "snap-0fb00000000000002"
VOLS = {"/dev/xvda": "vol-0fb00000000000001", "/dev/xvdc": "vol-0fb00000000000002",
        "/dev/xvdf": "vol-0fb00000000000003", "/dev/xvdb": "vol-0fb00000000000004"}
BUILDER, SG, VPC, SUBNET, PROFILE = "i-0fb00000000000001", "sg-0fc00000000000001", "vpc-0fa00000000000001", \
    "subnet-0fa00000000000001", "cb-offline-test-r1-builder"
UUID = "00000000-0000-4000-8000-000000000001"
ACCOUNT = "111122223333"
TAGS = [{"Key": "ManagedBy", "Value": MB}, {"Key": "RunId", "Value": RUN}]
IMAGE_TAGS = TAGS + [{"Key": "SandboxSlots", "Value": SLOTS}, {"Key": "Name", "Value": "cilium-bottlerocket-1.36-r1"}]


def good():
    return {
        "manifest.json": {"builds": [{"name": "bottlerocket", "builder_type": "amazon-ebssurrogate", "build_time": 1,
                                      "files": None, "artifact_id": f"us-west-2:{AMI}", "packer_run_uuid": UUID,
                                      "custom_data": {"run_id": RUN}}], "last_run_uuid": UUID},
        "images.json": {"Images": [{
            "ImageId": AMI, "State": "available", "Public": False, "Architecture": "x86_64",
            "VirtualizationType": "hvm", "EnaSupport": True, "SriovNetSupport": "simple", "ImdsSupport": "v2.0",
            "RootDeviceName": "/dev/xvda", "RootDeviceType": "ebs", "BootMode": "uefi-preferred", "Tags": IMAGE_TAGS,
            "BlockDeviceMappings": [
                {"DeviceName": "/dev/xvda", "Ebs": {"SnapshotId": SNAP_ROOT, "VolumeType": "gp3", "VolumeSize": 4}},
                {"DeviceName": "/dev/xvdb", "Ebs": {"SnapshotId": SNAP_DATA, "VolumeType": "gp3", "VolumeSize": 18}}]}]},
        "uefi.json": {"ImageId": AMI, "UefiData": {}},
        "snapshots.json": {"Snapshots": [
            {"SnapshotId": SNAP_ROOT, "VolumeId": VOLS["/dev/xvdf"], "State": "completed", "Tags": IMAGE_TAGS},
            {"SnapshotId": SNAP_DATA, "VolumeId": VOLS["/dev/xvdb"], "State": "completed", "Tags": IMAGE_TAGS}]},
        "instances.json": {"Reservations": [{"Instances": [{
            "InstanceId": BUILDER, "SubnetId": SUBNET, "SecurityGroups": [{"GroupId": SG}],
            "IamInstanceProfile": {"Arn": f"arn:aws:iam::{ACCOUNT}:instance-profile/{PROFILE}"},
            "MetadataOptions": {"HttpTokens": "required", "HttpPutResponseHopLimit": 1},
            "NetworkInterfaces": [{"NetworkInterfaceId": "eni-0fb00000000000001"}], "Tags": TAGS,
            "BlockDeviceMappings": [{"DeviceName": d, "Ebs": {"VolumeId": v}} for d, v in VOLS.items()]}]}]},
        "groups.json": {"SecurityGroups": [{
            "GroupId": SG, "VpcId": VPC, "IpPermissions": [], "Tags": TAGS,
            "IpPermissionsEgress": [{"IpProtocol": "tcp", "FromPort": 443, "ToPort": 443,
                                     "IpRanges": [{"CidrIp": "0.0.0.0/0"}], "Ipv6Ranges": [], "UserIdGroupPairs": [],
                                     "PrefixListIds": []}]}]},
        "volumes.json": {"Volumes": [{"VolumeId": v, "VolumeType": "gp3", "Tags": TAGS,
                                      "Attachments": [{"InstanceId": BUILDER, "Device": d}]} for d, v in VOLS.items()]},
        "role.json": {"Role": {"RoleName": PROFILE, "Tags": TAGS}},
        "profile.json": {"InstanceProfile": {"InstanceProfileName": PROFILE, "Tags": TAGS,
                                             "Roles": [{"RoleName": PROFILE}]}},
        "instances-terminated.json": {"Reservations": [{"Instances": [{"InstanceId": BUILDER,
                                                                         "State": {"Name": "terminated"}}]}]},
        "instances-running.json": {"Reservations": [{"Instances": [{"InstanceId": BUILDER,
                                                                      "State": {"Name": "running"}}]}]},
        "empty-volumes.json": {"Volumes": []},
        "empty-groups.json": {"SecurityGroups": []},
    }


def main(argv):
    if argv[0] == "good":
        os.makedirs(argv[1], exist_ok=True)
        for name, doc in good().items():
            with open(os.path.join(argv[1], name), "w") as f:
                json.dump(doc, f, indent=1)
        return 0
    if argv[0] == "mutate":
        d = json.load(open(argv[1]))
        exec(argv[3], {"d": d, "VOLS": VOLS})
        with open(argv[2], "w") as f:
            json.dump(d, f, indent=1)
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

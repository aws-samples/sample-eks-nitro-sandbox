#!/usr/bin/env python3
"""cost_gate.py -- the most one bubblewrap run can cost, checked before it creates anything.

setup.sh runs this before its first AWS or Kubernetes write, and run.sh before the model
turn. It reads a cost snapshot (COST_SNAPSHOT in .env), the pod manifest, the run's
envelope and the two image sizes, and exits 0 only when the worst case for one complete
run, through its clean up, is strictly below the cap. On success it prints that worst case
and its terms as JSON on standard output, which setup.sh keeps in the run record. On any
refusal it prints why on standard error and exits non-zero.

The snapshot is a JSON file you collect with read-only calls and keep outside the
repository, because its prices and offerings are your account's and Region's:

  schema                   "bubblewrap-cost-snapshot/1"
  captured_at              when it was collected, UTC, e.g. "2026-11-17T08:00:00Z"
  region, bedrock_model_id the run's AWS_REGION and BEDROCK_MODEL_ID
  provenance               where each part came from: "pricing", "offerings", "nodepools",
                           "node_class" and "collected_by", each a non-empty string
  nodepools                every NodePool on the cluster: [{"name", "taints",
                           "requirements"}] as kubectl prints them
  node_class_volume_gib    the size of the node volume the NodeClass gives each node
  offered_instance_types   every instance type offered in the Region, each
                           {"architectures": [...]} from DescribeInstanceTypes
  prices                   for each instance type in the set this script derives, exactly
                           {"ec2_usd_per_hour": on-demand Linux, shared tenancy,
                            "auto_mode_usd_per_hour": the EKS Auto Mode fee}
  unit_prices              the eight rates in UNIT_PRICES below

Every key is required and no other key is accepted. A price set that is missing a derived
type, or has one more, is refused: the pod's nodeSelector limits the node to an xlarge, and
the NodePools that can take the pod limit its family, so the set is every offered x86_64
type of those families and generations at that size, whichever of them EKS may choose.
"""
import argparse
import json
import re
import sys
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from pathlib import Path

CAP_USD = Decimal("5")
SCHEMA = "bubblewrap-cost-snapshot/1"
SNAPSHOT_KEYS = {"schema", "captured_at", "region", "bedrock_model_id", "provenance", "nodepools",
                 "node_class_volume_gib", "offered_instance_types", "prices", "unit_prices"}
PROVENANCE_KEYS = {"pricing", "offerings", "nodepools", "node_class", "collected_by"}
PRICE_KEYS = {"ec2_usd_per_hour", "auto_mode_usd_per_hour"}
UNIT_PRICES = {"ebs_gp3_usd_per_gb_month", "bedrock_input_usd_per_million_tokens",
               "bedrock_output_usd_per_million_tokens", "ecr_usd_per_gb_month",
               "s3_usd_per_gb_month", "s3_put_usd_per_1000", "s3_get_usd_per_10000",
               "nat_usd_per_gb"}
MAX_AGE = timedelta(hours=24)
MAX_SKEW = timedelta(minutes=5)
NODE_SIZE = "xlarge"
SIZE_LABEL = "eks.amazonaws.com/instance-size"
ENVELOPE_KEYS = ("turns", "output_tokens", "total_tokens", "max_tokens", "model_attempts",
                 "sdk_attempts", "max_request_bytes", "evidence_tool_calls")
IMAGES = ("supplier-api", "analyst")

# The finite terms below are this blueprint's own, each with where its number comes from.
# A gigabyte is counted as 10^9 bytes, which overstates every byte-priced charge.
GB = Decimal(10) ** 9
HOURS_PER_MONTH = Decimal(730)
# One run from setup through a clean up that deletes the run's own node
# (clean.sh --delete-aws --delete-node): the node bills for no longer than this.
ATTEMPT_HOURS = Decimal(2)
# run.sh starts the model turn only this soon after setup started (RUN_STARTED_AT), which
# leaves the rest of ATTEMPT_HOURS for the turn and for a clean up whose own waits add up
# to under half an hour. The clean up itself is yours to start: until it runs, the node
# keeps billing, and this bound assumes you start it when the run ends.
RUN_WINDOW = timedelta(hours=1)
# Storage is charged as if kept a whole month, although clean up deletes it within the run.
STORAGE_MONTHS = Decimal(1)
IMAGE_MAX_BYTES = 3 * 10 ** 9            # each image, uncompressed, as docker reports it
SEED_GENERATED_MAX_BYTES = 4096          # the one object analyst-lib.sh writes itself
# Every AWS CLI request is tried at most this often: setup.sh, run.sh and clean.sh set
# AWS_MAX_ATTEMPTS=3 in standard retry mode.
CLI_ATTEMPTS = 3
# S3 requests by one run, before retries: five seed puts, the controller's two report puts
# and its refused overwrite, plus its listing and deletes in clean up (counted at the put
# rate); and the controller's case, three proposals, refused read and two read-backs.
S3_PUT_REQUESTS = 5 + 2 + 1 + 4
S3_GET_REQUESTS = 1 + 3 + 1 + 2
# The kubelet pulls each image through the NAT gateway; this many attempts each is the
# allowance for retried and partial pulls inside setup's ten-minute wait.
PULL_ATTEMPTS = 6
# Everything else the new node sends through the NAT gateway while it starts and runs:
# its own system images and its control traffic.
NAT_FIXED_BYTES = 2 * 10 ** 9
# What Bedrock adds to each request beyond the JSON this turn sends: its tool-use prompt.
REQUEST_OVERHEAD_TOKENS = 2000
# A response token is never more than this many bytes on the wire.
BYTES_PER_OUTPUT_TOKEN = 8


class Refused(Exception):
    pass


def no_duplicates(pairs):
    seen = {}
    for key, value in pairs:
        if key in seen:
            raise Refused(f"the snapshot has the key {key!r} twice")
        seen[key] = value
    return seen


def exact_keys(what, value, keys):
    if not isinstance(value, dict):
        raise Refused(f"{what} must be an object")
    if set(value) != set(keys):
        missing, extra = sorted(set(keys) - set(value)), sorted(set(value) - set(keys))
        raise Refused(f"{what} is missing {missing} or has extra {extra}")


def positive(what, value):
    if isinstance(value, bool) or not isinstance(value, (int, Decimal)) or not value > 0:
        raise Refused(f"{what} must be a positive number, not {value!r}")
    if isinstance(value, Decimal) and not value.is_finite():
        raise Refused(f"{what} must be finite")
    return Decimal(value)


def no_constants(name):
    raise Refused(f"the snapshot holds {name}, which is not a price")


def load_snapshot(path, region, model_id, now):
    try:
        snapshot = json.loads(Path(path).read_text(), object_pairs_hook=no_duplicates,
                              parse_float=Decimal, parse_constant=no_constants)
    except (OSError, ValueError) as error:
        raise Refused(f"could not read the cost snapshot {path}: {error}")
    exact_keys("the snapshot", snapshot, SNAPSHOT_KEYS)
    if snapshot["schema"] != SCHEMA:
        raise Refused(f"the snapshot schema is {snapshot['schema']!r}, not {SCHEMA!r}")
    try:
        captured = datetime.strptime(snapshot["captured_at"], "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc)
    except (TypeError, ValueError):
        raise Refused("captured_at must be a UTC time such as 2026-11-17T08:00:00Z")
    if captured > now + MAX_SKEW:
        raise Refused(f"the snapshot was captured at {snapshot['captured_at']}, in the future")
    if now - captured > MAX_AGE:
        raise Refused(f"the snapshot was captured at {snapshot['captured_at']}, more than "
                      f"{MAX_AGE} ago; collect it again")
    if snapshot["region"] != region:
        raise Refused(f"the snapshot is for {snapshot['region']!r}, not {region!r}")
    if snapshot["bedrock_model_id"] != model_id:
        raise Refused(f"the snapshot prices {snapshot['bedrock_model_id']!r}, not {model_id!r}")
    exact_keys("provenance", snapshot["provenance"], PROVENANCE_KEYS)
    for key, value in snapshot["provenance"].items():
        if not isinstance(value, str) or not value.strip():
            raise Refused(f"provenance {key} must say where that part came from")
    exact_keys("unit_prices", snapshot["unit_prices"], UNIT_PRICES)
    for key, value in snapshot["unit_prices"].items():
        positive(f"unit price {key}", value)
    positive("node_class_volume_gib", snapshot["node_class_volume_gib"])
    return snapshot


def schedulable_pools(nodepools):
    """The NodePools the pod can land on: the pod and its RuntimeClass tolerate no taint."""
    if not isinstance(nodepools, list) or not nodepools:
        raise Refused("nodepools must list every NodePool on the cluster")
    names, pools = set(), []
    for pool in nodepools:
        exact_keys("a NodePool", pool, {"name", "taints", "requirements"})
        if not isinstance(pool["name"], str) or pool["name"] in names:
            raise Refused(f"NodePool name {pool['name']!r} is missing or repeated")
        names.add(pool["name"])
        taints = pool["taints"] or []
        if not isinstance(taints, list) or not isinstance(pool["requirements"], list):
            raise Refused(f"NodePool {pool['name']} has malformed taints or requirements")
        if any(t.get("effect") in ("NoSchedule", "NoExecute") for t in taints):
            continue
        pools.append(pool)
    if not pools:
        raise Refused("no NodePool can take the analyst pod")
    return pools


def pool_bounds(pool):
    """The families and the lowest generation this pool allows, or a refusal if unbounded."""
    found = {}
    for requirement in pool["requirements"]:
        key, operator = requirement.get("key"), requirement.get("operator")
        values = requirement.get("values") or []
        if key in found and key in ("eks.amazonaws.com/instance-category",
                                    "eks.amazonaws.com/instance-generation", "kubernetes.io/arch"):
            raise Refused(f"NodePool {pool['name']} sets {key} twice")
        found[key] = (operator, values)
    category = found.get("eks.amazonaws.com/instance-category")
    if not category or category[0] != "In" or not set(category[1]) <= {"c", "m", "r"}:
        raise Refused(f"NodePool {pool['name']} does not limit the family to c, m or r, so "
                      "the priced set does not cover it")
    generation = found.get("eks.amazonaws.com/instance-generation")
    if not generation or generation[0] != "Gt" or len(generation[1]) != 1 or \
            not str(generation[1][0]).isdigit():
        raise Refused(f"NodePool {pool['name']} does not set a lowest generation")
    arch = found.get("kubernetes.io/arch")
    if not arch or arch[0] != "In" or set(arch[1]) != {"amd64"}:
        raise Refused(f"NodePool {pool['name']} does not limit nodes to amd64")
    return set(category[1]), int(generation[1][0])


def derived_types(snapshot):
    """Every offered x86_64 type the schedulable pools allow at the pinned size."""
    offered = snapshot["offered_instance_types"]
    if not isinstance(offered, dict) or not offered:
        raise Refused("offered_instance_types must list the Region's instance types")
    bounds = [pool_bounds(pool) for pool in schedulable_pools(snapshot["nodepools"])]
    pattern = re.compile(r"^([cmr])(\d+)([a-z-]*)\." + NODE_SIZE + "$")
    expected = set()
    for name, details in offered.items():
        exact_keys(f"offered type {name}", details, {"architectures"})
        match = pattern.match(name)
        if not match or "x86_64" not in details["architectures"]:
            continue
        family, generation = match.group(1), int(match.group(2))
        if any(family in families and generation > lowest for families, lowest in bounds):
            expected.add(name)
    if not expected:
        raise Refused("no offered type matches the pinned size and the NodePools")
    return expected


def node_rate(snapshot, expected):
    prices = snapshot["prices"]
    if not isinstance(prices, dict):
        raise Refused("prices must be an object")
    missing, extra = sorted(expected - set(prices)), sorted(set(prices) - expected)
    if missing or extra:
        raise Refused(f"the price set does not match the derived set: missing {missing}, "
                      f"extra {extra}")
    worst, worst_type = Decimal(0), None
    for name in sorted(expected):
        exact_keys(f"the price of {name}", prices[name], PRICE_KEYS)
        rate = sum(positive(f"{name} {key}", prices[name][key]) for key in PRICE_KEYS)
        if rate > worst:
            worst, worst_type = rate, name
    return worst, worst_type


def manifest_size(path):
    """The pod's nodeSelector, read from the manifest: it must pin exactly the size."""
    lines = Path(path).read_text().splitlines()
    starts = [i for i, line in enumerate(lines) if line == "  nodeSelector:"]
    if len(starts) != 1 or "  runtimeClassName: isolated-sandbox" not in lines:
        raise Refused(f"{path} must have one spec.nodeSelector beside its runtime class")
    selector = {}
    for line in lines[starts[0] + 1:]:
        if not line.startswith("    ") or line.lstrip().startswith("#"):
            break
        key, _, value = line.strip().partition(": ")
        selector[key] = value
    if selector != {SIZE_LABEL: NODE_SIZE}:
        raise Refused(f"{path} must select exactly {SIZE_LABEL}: {NODE_SIZE}, not {selector}")


def envelope(path):
    try:
        loaded = json.loads(Path(path).read_text(), object_pairs_hook=no_duplicates)
    except (OSError, ValueError) as error:
        raise Refused(f"could not read the run envelope {path}: {error}")
    exact_keys("the run envelope", loaded, {"model", "reports"})
    exact_keys("the model envelope", loaded["model"], ENVELOPE_KEYS)
    exact_keys("the reports envelope", loaded["reports"], {"objects", "object_max_bytes"})
    for section in ("model", "reports"):
        for key, value in loaded[section].items():
            if type(value) is not int or value <= 0:
                raise Refused(f"envelope {section}.{key} must be a positive integer")
    return loaded


def worst_case(snapshot, expected, run, image_bytes, seed_bytes):
    units = {key: Decimal(value) for key, value in snapshot["unit_prices"].items()}
    rate, rate_type = node_rate(snapshot, expected)
    volume_hour = Decimal(snapshot["node_class_volume_gib"]) * units["ebs_gp3_usd_per_gb_month"] \
        / HOURS_PER_MONTH
    model, reports = run["model"], run["reports"]
    calls = model["turns"] * model["model_attempts"] * model["sdk_attempts"]
    input_tokens = calls * (model["max_request_bytes"] + REQUEST_OVERHEAD_TOKENS)
    output_tokens = calls * model["max_tokens"]
    images = sum(image_bytes.values())
    report_bytes = reports["objects"] * reports["object_max_bytes"]
    objects = seed_bytes + report_bytes
    nat_bytes = (PULL_ATTEMPTS * images + CLI_ATTEMPTS * objects + NAT_FIXED_BYTES
                 + calls * (model["max_request_bytes"] + BYTES_PER_OUTPUT_TOKEN * model["max_tokens"]))
    terms = {
        "node": ATTEMPT_HOURS * (rate + volume_hour),
        "bedrock": (input_tokens * units["bedrock_input_usd_per_million_tokens"]
                    + output_tokens * units["bedrock_output_usd_per_million_tokens"])
        / Decimal(10 ** 6),
        "ecr": images / GB * units["ecr_usd_per_gb_month"] * STORAGE_MONTHS,
        "s3": objects / GB * units["s3_usd_per_gb_month"] * STORAGE_MONTHS
        + CLI_ATTEMPTS * S3_PUT_REQUESTS * units["s3_put_usd_per_1000"] / 1000
        + CLI_ATTEMPTS * S3_GET_REQUESTS * units["s3_get_usd_per_10000"] / 10000,
        "nat": nat_bytes / GB * units["nat_usd_per_gb"],
    }
    total = sum(terms.values())
    return total, terms, {"worst_node_type": rate_type, "node_usd_per_hour": str(rate),
                          "priced_types": len(expected), "model_requests": calls,
                          "image_bytes": images, "object_bytes": objects, "nat_bytes": nat_bytes}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--snapshot", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--envelope", required=True)
    parser.add_argument("--region", required=True)
    parser.add_argument("--model-id", required=True)
    parser.add_argument("--image", action="append", default=[], metavar="NAME=BYTES")
    parser.add_argument("--seed-object", action="append", default=[], metavar="PATH")
    parser.add_argument("--started-at", metavar="RUN_STARTED_AT",
                        help="when setup started; run.sh passes it from the run record")
    parser.add_argument("--now", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    try:
        now = (datetime.strptime(args.now, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
               if args.now else datetime.now(timezone.utc))
        if args.started_at is not None:
            try:
                started = datetime.strptime(args.started_at, "%Y-%m-%dT%H:%M:%SZ").replace(
                    tzinfo=timezone.utc)
            except ValueError:
                raise Refused(f"the run record's RUN_STARTED_AT {args.started_at!r} is not a UTC time")
            if started > now + MAX_SKEW or now - started > RUN_WINDOW:
                raise Refused(f"setup started at {args.started_at}, and a run starts within "
                              f"{RUN_WINDOW} of that so the node's hours stay inside the bound; "
                              "run ./scripts/clean.sh --delete-aws --delete-node")
        image_bytes = {}
        for item in args.image:
            name, _, value = item.partition("=")
            if name not in IMAGES or name in image_bytes or not value.isdigit():
                raise Refused(f"--image {item!r} is not one of {IMAGES} with a byte count")
            if not 0 < int(value) <= IMAGE_MAX_BYTES:
                raise Refused(f"the {name} image is {value} bytes; the limit is {IMAGE_MAX_BYTES}")
            image_bytes[name] = int(value)
        if set(image_bytes) != set(IMAGES):
            raise Refused(f"both images need a size: {IMAGES}")
        if len(args.seed_object) != 4 or len(set(args.seed_object)) != 4:
            raise Refused("the four seed fixture files are required")
        seed_bytes = sum(Path(p).stat().st_size for p in args.seed_object) + SEED_GENERATED_MAX_BYTES
        manifest_size(args.manifest)
        run = envelope(args.envelope)
        snapshot = load_snapshot(args.snapshot, args.region, args.model_id, now)
        expected = derived_types(snapshot)
        total, terms, facts = worst_case(snapshot, expected, run, image_bytes, seed_bytes)
    except (Refused, OSError) as error:
        print(f"cost check refused: {error}", file=sys.stderr)
        return 1
    except (TypeError, AttributeError, KeyError, ArithmeticError) as error:
        # A malformed snapshot that got past the shape checks: refuse rather than guess.
        print(f"cost check refused: malformed input ({type(error).__name__}: {error})",
              file=sys.stderr)
        return 1
    if not total < CAP_USD:
        print(f"cost check refused: one run can cost up to USD {total:.6f}, which is not "
              f"below USD {CAP_USD}", file=sys.stderr)
        return 1
    print(json.dumps({"worst_case_usd": str(total), "cap_usd": str(CAP_USD),
                      "terms_usd": {k: str(v) for k, v in terms.items()}, **facts,
                      "snapshot_captured_at": snapshot["captured_at"]}, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())

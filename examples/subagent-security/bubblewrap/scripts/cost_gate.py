"""cost_gate.py -- the most one bubblewrap run can cost, checked before it creates anything.

setup.sh runs this before its first AWS or Kubernetes write, and run.sh before the model
turn. It exits 0 only when the worst case for one complete run, through its clean up, is
strictly below USD 5; exactly USD 5 is refused. On success it prints that worst case, its
terms, the run's timeline and the snapshot's fingerprint as JSON on standard output, which
setup.sh keeps in the run record. On any refusal it prints why on standard error and exits
non-zero.

Its inputs:

  --snapshot   the folder scripts/cost_snapshot.py collect wrote (COST_SNAPSHOT in .env).
               Every price, offering, NodePool and NodeClass is rebuilt from the raw reads
               in it, for exactly this account, Region, cluster and kube context, and the
               folder must have been collected within the hour before setup started.
  --manifest   the analyst pod, which must pin the node to an xlarge.
  --envelope   src/run_envelope.json, the model turn's and the reports' finite bounds.
  --image      both images' sizes, measured by setup.sh before anything is pushed.
  --extra-s3   S3 requests made outside the scripts during the run, such as an operator's
               own reads of the bucket, as PUT=<n>,GET=<n>. The page's own steps make none.

Each term below names what bounds it. A term with nothing to bound it is not estimated: the
check refuses instead. That is why a node subnet routing through a NAT gateway is refused
(cost_snapshot.py says why) and why only a model with a known context window is accepted.
"""
import argparse
import json
import re
import sys
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from pathlib import Path

CAP_USD = Decimal("5")
PRICE_KEYS = {"ec2_usd_per_hour", "auto_mode_usd_per_hour"}
UNIT_PRICES = {"ebs_gp3_usd_per_gb_month", "bedrock_input_usd_per_million_tokens",
               "bedrock_output_usd_per_million_tokens", "ecr_usd_per_gb_month",
               "s3_usd_per_gb_month", "s3_put_usd_per_1000", "s3_get_usd_per_10000"}
MAX_AGE = timedelta(hours=1)
MAX_SKEW = timedelta(minutes=5)
NODE_SIZE = "xlarge"
SIZE_LABEL = "eks.amazonaws.com/instance-size"
ENVELOPE_KEYS = ("turns", "output_tokens", "total_tokens", "max_tokens", "model_attempts",
                 "sdk_attempts", "max_request_bytes", "evidence_tool_calls")
IMAGES = ("supplier-api", "analyst")

# A gigabyte is counted as 10^9 bytes, which overstates every byte-priced charge.
GB = Decimal(10) ** 9
HOURS_PER_MONTH = Decimal(730)

# The run's timeline, in seconds from RUN_STARTED_AT, and what enforces each part.
#   RUN_WINDOW_S       run.sh refuses to start the model turn after this (this check, with
#                      --started-at).
#   CLEANUP_START_S    scripts/deadline.sh starts clean.sh --delete-aws --delete-node then,
#                      and the analyst pod's activeDeadlineSeconds ends it then. A failed
#                      setup.sh or run.sh starts that clean up at once, earlier.
#   CLEAN_TO_TERMINAL_S  the longest clean.sh takes, from its start, to see the run's
#                      instance terminated through its NodeClaim: its four namespace deletes
#                      wait 5 minutes each, its node step's reads give up after 60 seconds,
#                      and its two waits stop after 10 minutes each by the clock.
#   FALLBACK_S         the direct termination (--allow-instance-termination) if EKS has not
#                      removed the node by then: its dry run, every check again, and a
#                      10-minute wait. A person starts it; nothing here can.
RUN_WINDOW_S = 40 * 60
CLEANUP_START_S = 60 * 60
CLEAN_TO_TERMINAL_S = 50 * 60
FALLBACK_S = 20 * 60
# The node bills for no longer than this: the clean up's start, its managed path, and the
# fallback. The analyst pod cannot start the model turn later than RUN_WINDOW_S.
ATTEMPT_S = CLEANUP_START_S + CLEAN_TO_TERMINAL_S + FALLBACK_S
# Storage is charged as if kept a whole month, although clean up deletes it within the run.
STORAGE_MONTHS = Decimal(1)
IMAGE_MAX_BYTES = 3 * 10 ** 9            # each image, uncompressed, as docker reports it
SEED_GENERATED_MAX_BYTES = 4096          # the one object analyst-lib.sh writes itself

# Input tokens: no request can hold more than the model's context window, so that is the
# most input any one request can bill. Bedrock rejects a longer request rather than bill
# it. Claude Sonnet 4.5's window is 200,000 tokens (Anthropic, Models overview; Amazon
# Bedrock's model card); the larger 1M window needs a beta header this blueprint never
# sends. Output tokens: Bedrock stops each response at max_tokens.
MODEL_CONTEXT_TOKENS = {"global.anthropic.claude-sonnet-4-5-20250929-v1:0": 200_000}

# Retries. Every AWS CLI request is sent at most CLI_ATTEMPTS times: setup.sh and clean.sh
# export AWS_MAX_ATTEMPTS=3 (which counts the first send) in standard mode, and run.sh makes
# no AWS CLI call. The controller's S3 client sends at most SDK_S3_ATTEMPTS times
# (total_max_attempts in controller.py).
CLI_ATTEMPTS = 3
SDK_S3_ATTEMPTS = 3

# Every S3 request one run can make, from each call site, by S3's pricing class: "put" is
# PUT, COPY, POST and LIST, "get" is GET and every other request except DELETE, and DELETE
# is free. Each row is (file, the call as written there, how many times that text appears,
# class, the most times the call can run in one run, how it is retried). Calls in branches
# that exclude each other count once; calls in a loop count its length, which the tests
# read from the same files. A test fails when the code has an S3 call this table lacks.
SEED_PROPOSALS = 3                       # analyst/fixtures/proposals, one put each
CASE_SUPPLIERS = 3                       # the suppliers in analyst/fixtures/case.json
CLEAN_RUNS = 2                           # the automatic or deadline clean up, and yours
S3_SITES = (
    ("analyst/scripts/analyst-lib.sh", "lookup NoSuchBucket s3api get-bucket-tagging", 1, "get", 1, "cli"),
    ("analyst/scripts/analyst-lib.sh", "aws s3api head-bucket", 1, "get", 1, "cli"),
    ("analyst/scripts/analyst-lib.sh", "aws s3api create-bucket", 2, "put", 1, "cli"),
    ("analyst/scripts/analyst-lib.sh", "aws s3api put-bucket-tagging", 1, "put", 1, "cli"),
    ("analyst/scripts/analyst-lib.sh", "aws s3api put-public-access-block", 1, "put", 1, "cli"),
    ("analyst/scripts/analyst-lib.sh", "aws s3api put-bucket-encryption", 1, "put", 1, "cli"),
    ("analyst/scripts/analyst-lib.sh", "    s3api get-bucket-tagging --bucket", 1, "get", 1, "cli"),
    ("analyst/scripts/analyst-lib.sh", "s3api get-public-access-block", 1, "get", 1, "cli"),
    ("analyst/scripts/analyst-lib.sh", "s3api get-bucket-encryption", 1, "get", 1, "cli"),
    ("analyst/scripts/analyst-lib.sh", "s3api get-bucket-acl", 1, "get", 1, "cli"),
    ("analyst/scripts/analyst-lib.sh", "lookup NoSuchBucketPolicy s3api get-bucket-policy", 1, "get", 1, "cli"),
    ("analyst/scripts/analyst-lib.sh", "aws s3api put-object", 3, "put", 2 + SEED_PROPOSALS, "cli"),
    ("bubblewrap/src/controller.py", "s3.get_object(Bucket=BUCKET,\n", 2, "get", 1 + CASE_SUPPLIERS, "sdk"),
    ("bubblewrap/src/controller.py", '("overwriting a source proposal", "put_object"', 1, "put", 1, "sdk"),
    ("bubblewrap/src/controller.py", '("deleting a source proposal", "delete_object"', 1, "free", 1, "sdk"),
    ("bubblewrap/src/controller.py", '("reading another case\'s object", "get_object"', 1, "get", 1, "sdk"),
    ("bubblewrap/src/controller.py", "s3.put_object(Bucket=BUCKET, Key=f\"{prefix}/{name}\"", 1, "put", 2, "sdk"),
    ("bubblewrap/src/controller.py", "s3.get_object(Bucket=BUCKET, Key=f\"{prefix}/{name}\")", 1, "get", 2, "sdk"),
    # aws s3 rm --recursive lists the bucket (one page holds the at most 7 objects any run
    # writes) and deletes each object; delete-bucket is a DELETE.
    ("bubblewrap/scripts/clean.sh", "lookup NoSuchBucket s3api get-bucket-tagging", 2, "get", 2 * CLEAN_RUNS, "cli"),
    ("bubblewrap/scripts/clean.sh", "aws s3 rm", 1, "put", CLEAN_RUNS, "cli"),
    ("bubblewrap/scripts/clean.sh", "aws s3api delete-bucket", 1, "free", CLEAN_RUNS, "cli"),
)
ATTEMPTS = {"cli": CLI_ATTEMPTS, "sdk": SDK_S3_ATTEMPTS}


class Refused(Exception):
    pass


def no_duplicates(pairs):
    seen = {}
    for key, value in pairs:
        if key in seen:
            raise Refused(f"the input has the key {key!r} twice")
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


def utc(text, what):
    try:
        return datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        raise Refused(f"{what} {text!r} is not a UTC time such as 2026-11-17T08:00:00Z")


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
    # cost_snapshot.build reads exactly one price per derived type, so the two sets match
    prices = snapshot["prices"]
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
    if "  activeDeadlineSeconds: <ACTIVE_DEADLINE_SECONDS>" not in lines:
        raise Refused(f"{path} must end the pod at the run's clean-up deadline (activeDeadlineSeconds)")


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


def extra_s3(text):
    """PUT=<n>,GET=<n>, either part optional, both whole numbers."""
    counts = {"put": 0, "get": 0}
    for part in filter(None, (text or "").split(",")):
        key, _, value = part.partition("=")
        if key.lower() not in counts or not value.isdigit():
            raise Refused(f"--extra-s3 {text!r} is not PUT=<n>,GET=<n>")
        counts[key.lower()] = int(value)
    return counts


def s3_requests(extra):
    """The most S3 requests of each class one run can send, retries included."""
    totals = {"put": 0, "get": 0, "free": 0}
    for _, _, _, kind, runs, retry in S3_SITES:
        totals[kind] += runs * ATTEMPTS[retry]
    totals["put"] += extra["put"] * CLI_ATTEMPTS
    totals["get"] += extra["get"] * CLI_ATTEMPTS
    return totals


def worst_case(snapshot, expected, run, image_bytes, seed_bytes, model_id, extra):
    units = {key: Decimal(value) for key, value in snapshot["unit_prices"].items()}
    rate, rate_type = node_rate(snapshot, expected)
    volume_hour = Decimal(snapshot["node_class_volume_gib"]) * units["ebs_gp3_usd_per_gb_month"] \
        / HOURS_PER_MONTH
    model, reports = run["model"], run["reports"]
    # every HTTP send to Bedrock: Strands turns, times its tries per call, times the SDK's
    sends = model["turns"] * model["model_attempts"] * model["sdk_attempts"]
    input_tokens = sends * MODEL_CONTEXT_TOKENS[model_id]
    output_tokens = sends * model["max_tokens"]
    images = sum(image_bytes.values())
    objects = seed_bytes + reports["objects"] * reports["object_max_bytes"]
    requests = s3_requests(extra)
    hours = Decimal(ATTEMPT_S) / 3600
    terms = {
        "node": hours * (rate + volume_hour),
        "bedrock": (input_tokens * units["bedrock_input_usd_per_million_tokens"]
                    + output_tokens * units["bedrock_output_usd_per_million_tokens"])
        / Decimal(10 ** 6),
        "ecr": images / GB * units["ecr_usd_per_gb_month"] * STORAGE_MONTHS,
        "s3": objects / GB * units["s3_usd_per_gb_month"] * STORAGE_MONTHS
        + requests["put"] * units["s3_put_usd_per_1000"] / 1000
        + requests["get"] * units["s3_get_usd_per_10000"] / 10000,
        # cost_snapshot.build refuses any node subnet that routes through a NAT gateway
        "nat": Decimal(0),
    }
    total = sum(terms.values())
    return total, terms, {"worst_node_type": rate_type, "node_usd_per_hour": str(rate),
                          "priced_types": len(expected), "bedrock_sends": sends,
                          "input_tokens": input_tokens, "output_tokens": output_tokens,
                          "image_bytes": images, "object_bytes": objects,
                          "s3_requests": requests, "node_hours": str(hours)}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--snapshot", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--envelope", required=True)
    parser.add_argument("--region", required=True)
    parser.add_argument("--account", required=True)
    parser.add_argument("--cluster-name", required=True)
    parser.add_argument("--kube-context", required=True)
    parser.add_argument("--model-id", required=True)
    parser.add_argument("--extra-s3", default="")
    parser.add_argument("--image", action="append", default=[], metavar="NAME=BYTES")
    parser.add_argument("--seed-object", action="append", default=[], metavar="PATH")
    parser.add_argument("--started-at", metavar="RUN_STARTED_AT",
                        help="when setup started; run.sh passes it from the run record")
    parser.add_argument("--now", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import cost_snapshot
    try:
        now = utc(args.now, "--now") if args.now else datetime.now(timezone.utc)
        reference = now
        if args.started_at is not None:
            started = utc(args.started_at, "the run record's RUN_STARTED_AT")
            if started > now + MAX_SKEW or now - started > timedelta(seconds=RUN_WINDOW_S):
                raise Refused(f"setup started at {args.started_at}, and a run starts within "
                              f"{timedelta(seconds=RUN_WINDOW_S)} of that so the node's hours stay "
                              "inside the bound; the run's own clean up removes it")
            reference = started
        if not re.fullmatch(r"\d{12}", args.account) or not args.cluster_name or not args.kube_context:
            raise Refused("the account, cluster name and kube context must all be given")
        if args.model_id not in MODEL_CONTEXT_TOKENS:
            raise Refused(f"no context window is known for {args.model_id!r}, so its input tokens "
                          "have no bound")
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
        extra = extra_s3(args.extra_s3)
        manifest_size(args.manifest)
        run = envelope(args.envelope)
        try:
            snapshot, fingerprint = cost_snapshot.build(
                args.snapshot, args.account, args.region, args.cluster_name, args.kube_context,
                args.model_id, lambda pools, types: derived_types(
                    {"nodepools": pools, "offered_instance_types": types}))
        except cost_snapshot.Bad as error:
            raise Refused(f"the cost snapshot {args.snapshot}: {error}")
        captured = utc(snapshot["captured_at"], "the snapshot's captured_at")
        if captured > now + MAX_SKEW:
            raise Refused(f"the snapshot was captured at {snapshot['captured_at']}, in the future")
        if reference - captured > MAX_AGE:
            raise Refused(f"the snapshot was captured at {snapshot['captured_at']}, more than "
                          f"{MAX_AGE} before the run; collect it again")
        exact_keys("unit_prices", snapshot["unit_prices"], UNIT_PRICES)
        for key, value in snapshot["unit_prices"].items():
            positive(f"unit price {key}", value)
        positive("the node volume", snapshot["node_class_volume_gib"])
        expected = derived_types(snapshot)
        total, terms, facts = worst_case(snapshot, expected, run, image_bytes, seed_bytes,
                                         args.model_id, extra)
    except (Refused, OSError) as error:
        print(f"cost check refused: {error}", file=sys.stderr)
        return 1
    except (TypeError, AttributeError, KeyError, ValueError, ArithmeticError) as error:
        # A malformed input that got past the shape checks: refuse rather than guess.
        print(f"cost check refused: malformed input ({type(error).__name__}: {error})",
              file=sys.stderr)
        return 1
    if not total < CAP_USD:
        print(f"cost check refused: one run can cost up to USD {total:.6f}, which is not "
              f"below USD {CAP_USD}", file=sys.stderr)
        return 1
    print(json.dumps({"worst_case_usd": str(total), "cap_usd": str(CAP_USD),
                      "terms_usd": {k: str(v) for k, v in terms.items()}, **facts,
                      "snapshot_captured_at": snapshot["captured_at"],
                      "snapshot_sha256": fingerprint,
                      "timeline_s": {"run_window": RUN_WINDOW_S, "cleanup_start": CLEANUP_START_S,
                                     "clean_to_terminal": CLEAN_TO_TERMINAL_S,
                                     "fallback": FALLBACK_S, "attempt": ATTEMPT_S}},
                     sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())

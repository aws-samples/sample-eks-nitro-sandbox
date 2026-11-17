"""cost_gate.py -- the most one bubblewrap run can cost, checked before it creates anything.

setup.sh runs this before its first AWS or Kubernetes write, and run.sh before the model
turn. It exits 0 only when the worst case for one complete run, through its clean up, is
strictly below USD 5; exactly USD 5 is refused. On success it prints that worst case, its
terms, the run's timeline and the snapshot's fingerprint as JSON on standard output, which
setup.sh keeps in the run record. On any refusal it prints why on standard error and exits
non-zero.

Its inputs:

  --snapshot   the folder setup.sh collected with scripts/cost_snapshot.py collect, in the
               run's own directory. Every price, offering, NodePool and NodeClass is rebuilt
               from the raw reads in it, for exactly this account, Region, cluster and kube
               context, and the folder must have been collected within the hour before.
  --identity   the account, role, cluster ARN, endpoint, Region and context setup.sh acts
               through (run-lib.sh identity_now); the reads must have been made as exactly that.
  --manifest   the analyst pod, which must pin the node to an xlarge.
  --envelope   src/run_envelope.json, the model turn's and the reports' finite bounds.
  --image      both images' sizes, measured by setup.sh before anything is pushed.
  --extra-s3   S3 requests made outside the scripts during the run, such as an operator's
               own reads of the bucket, as PUT=<n>,GET=<n>. The page's own steps make none.

Each term below names what bounds it. A term with nothing to bound it is not estimated: the
check refuses instead. That is why cost_snapshot.py refuses every node network path that is
charged per byte, and why only a model with a known context window is accepted. The numbers
that come from the scripts themselves (the clean up's time budget, how many times it may
run, the lock wait at the deadline, every S3 call and the length of each loop around one)
are read from those scripts here, so the scripts and this check cannot disagree.
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
#   CLEANUP_START_S    both pods end then, in the cluster: setup.sh lowers each pod's
#                      activeDeadlineSeconds so it counts to exactly that time. From then the
#                      node holds no workload but DaemonSets, and its NodePool removes it
#                      within empty_node_after_s (read from the NodePool, at most 600) plus
#                      NODE_REMOVE_S. The page's ordinary pod, if started just before, ends
#                      ORDINARY_POD_S later (its own sleep, restartPolicy Never).
#                      scripts/deadline.sh also starts clean.sh then, on this machine; it
#                      may wait for the run lock (read from deadline.sh), and clean.sh stops
#                      all its calls after CLEAN_BUDGET_S (read from clean.sh) plus the
#                      longest single call it can be in when that runs out.
# The node is priced until the later of those two ends: either one removes it.
RUN_WINDOW_S = 40 * 60
CLEANUP_START_S = 60 * 60
NODE_REMOVE_S = 10 * 60
ORDINARY_POD_S = 600
LONGEST_CLEAN_CALL_S = 3 * (10 + 60) + 30   # three AWS CLI tries at 10 s + 60 s, or a 30 s wait
# Storage is charged as if kept a whole month; setup.sh also has every image and object
# expire a day after it is written, so a clean up that never runs still ends that charge.
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
# is free (a batch delete is a POST, and is counted as "put"). Each row is (file, the call as
# written there, how many times that text appears, class, the most times the call can run in
# one run, how it is retried). Calls in branches that exclude each other count once; calls
# in a loop count its length. s3_ledger() checks this table against the files every time:
# each row's text must appear exactly its count of times, every S3 call in those files must
# lie inside a row's text, and the loop lengths and clean-up runs are read from the sources.
S3_FILES = ("analyst/scripts/analyst-lib.sh", "bubblewrap/scripts/setup.sh", "bubblewrap/scripts/run.sh",
            "bubblewrap/scripts/clean.sh", "bubblewrap/scripts/clean-node.sh", "bubblewrap/scripts/run-lib.sh",
            "bubblewrap/scripts/deadline.sh", "bubblewrap/src/controller.py")
S3_CALL = re.compile(r"\bs3api [a-z0-9-]+|\baws s3 [a-z]+|\bs3\.[a-z_]+\(|\(\"[^\"]+\", \"[a-z_]+_object\""
                     r"|getattr\(s3, ")


def s3_sites(seed_proposals, case_suppliers, clean_runs):
    lib, setup, ctl, clean = ("analyst/scripts/analyst-lib.sh", "bubblewrap/scripts/setup.sh",
                              "bubblewrap/src/controller.py", "bubblewrap/scripts/clean.sh")
    return (
        (lib, "lookup NoSuchBucket s3api get-bucket-tagging", 1, "get", 1, "cli"),
        (lib, "aws s3api head-bucket", 1, "get", 1, "cli"),
        (lib, "aws s3api create-bucket", 2, "put", 1, "cli"),
        (lib, "aws s3api put-bucket-tagging", 1, "put", 1, "cli"),
        (lib, "aws s3api put-public-access-block", 1, "put", 1, "cli"),
        (lib, "aws s3api put-bucket-encryption", 1, "put", 1, "cli"),
        (lib, "    s3api get-bucket-tagging --bucket", 1, "get", 1, "cli"),
        (lib, "s3api get-public-access-block", 1, "get", 1, "cli"),
        (lib, "s3api get-bucket-encryption", 1, "get", 1, "cli"),
        (lib, "s3api get-bucket-acl", 1, "get", 1, "cli"),
        (lib, "lookup NoSuchBucketPolicy s3api get-bucket-policy", 1, "get", 1, "cli"),
        (lib, "aws s3api put-object", 3, "put", 2 + seed_proposals, "cli"),
        (setup, "lookup NoSuchBucket s3api get-bucket-tagging", 1, "get", 1, "cli"),
        (setup, "aws s3api get-bucket-versioning", 1, "get", 1, "cli"),
        (setup, "aws s3api put-bucket-lifecycle-configuration", 1, "put", 1, "cli"),
        (setup, "s3api get-bucket-lifecycle-configuration", 1, "get", 1, "cli"),
        (ctl, "s3.get_object(Bucket=BUCKET,\n", 2, "get", 1 + case_suppliers, "sdk"),
        (ctl, '("overwriting a source proposal", "put_object"', 1, "put", 1, "sdk"),
        (ctl, '("deleting a source proposal", "delete_object"', 1, "free", 1, "sdk"),
        (ctl, '("reading another case\'s object", "get_object"', 1, "get", 1, "sdk"),
        # the one call that sends the three refusals above, which already count it
        (ctl, "getattr(s3, operation)(**params)", 1, "free", 0, "sdk"),
        (ctl, "s3.put_object(Bucket=BUCKET, Key=f\"{prefix}/{name}\"", 1, "put", 2, "sdk"),
        (ctl, "s3.get_object(Bucket=BUCKET, Key=f\"{prefix}/{name}\")", 1, "get", 2, "sdk"),
        (clean, "lookup NoSuchBucket s3api get-bucket-tagging", 2, "get", 2 * clean_runs, "cli"),
        (clean, "aws s3api list-objects-v2", 1, "put", clean_runs, "cli"),
        (clean, "aws s3api delete-objects", 1, "put", clean_runs, "cli"),
        (clean, "aws s3api delete-bucket", 1, "free", clean_runs, "cli"),
    )


ATTEMPTS = {"cli": CLI_ATTEMPTS, "sdk": SDK_S3_ATTEMPTS}


def source_number(section, path, pattern, what):
    """One whole number a sample script sets, read from the script itself."""
    found = re.findall(pattern, (section / path).read_text(), re.MULTILINE)
    if len(found) != 1 or not str(found[0]).isdigit():
        raise Refused(f"could not read {what} from {path}")
    return int(found[0])


def s3_ledger(section):
    """The S3 table above, checked against the files it describes, and the scripts' own numbers."""
    proposals = re.findall(r"^ANALYST_PROPOSALS=\(([a-z ]+)\)$",
                           (section / "analyst/scripts/analyst-lib.sh").read_text(), re.MULTILINE)
    if len(proposals) != 1:
        raise Refused("could not read the seeded proposals from analyst-lib.sh")
    suppliers = json.loads((section / "analyst/fixtures/case.json").read_text()).get("suppliers")
    if not isinstance(suppliers, list) or not suppliers:
        raise Refused("could not read the case's suppliers")
    clean_runs = source_number(section, "bubblewrap/scripts/clean.sh", r"^CLEAN_RUNS_MAX=(\d+)$",
                               "the most clean-up runs")
    sites = s3_sites(len(proposals[0].split()), len(suppliers), clean_runs)
    for path in S3_FILES:
        text = (section / path).read_text()
        spans = []
        for file, call, count, _, _, _ in sites:
            if file != path:
                continue
            starts = [m.start() for m in re.finditer(re.escape(call), text)]
            if len(starts) != count:
                raise Refused(f"the S3 ledger expects {call.strip()!r} {count} time(s) in {path}, "
                              f"and it is there {len(starts)} time(s)")
            spans += [(start, start + len(call)) for start in starts]
        for match in S3_CALL.finditer(text):
            if not any(start <= match.start() < end for start, end in spans):
                line = text.count("\n", 0, match.start()) + 1
                raise Refused(f"{path}:{line} makes the S3 call {match.group(0)!r}, which the ledger lacks")
    return sites, clean_runs


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
    pod_lifetime(path, lines)


def pod_lifetime(path, lines):
    """A pod that ends at the run's deadline on its own and tolerates no taint of its own."""
    for line in ("  activeDeadlineSeconds: <ACTIVE_DEADLINE_SECONDS>", "  restartPolicy: Never"):
        if line not in lines:
            raise Refused(f"{path} must end at the run's clean-up deadline ({line.strip()})")
    if any(re.match(r"^\s*tolerations:", line) for line in lines):
        raise Refused(f"{path} carries tolerations, which could let it onto a NodePool this check "
                      "treats as closed to it")


def supplier_pod(path):
    """The supplier API's pod: bound to the analyst pod's node, and ending when it does."""
    lines = Path(path).read_text().splitlines()
    if "kind: Pod" not in lines or "  nodeName: <NODE_NAME>" not in lines or \
            any(line.startswith("kind:") and line != "kind: Pod" for line in lines):
        raise Refused(f"{path} must be one pod bound to the analyst pod's node (nodeName)")
    pod_lifetime(path, lines)


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
    """PUT=<n>,GET=<n>, either part optional and neither twice, both whole numbers."""
    counts, seen = {"put": 0, "get": 0}, set()
    for part in filter(None, (text or "").split(",")):
        key, _, value = part.partition("=")
        if key.lower() not in counts or key.lower() in seen or not value.isdigit():
            raise Refused(f"--extra-s3 {text!r} is not PUT=<n>,GET=<n> with each class at most once")
        seen.add(key.lower())
        counts[key.lower()] = int(value)
    return counts


def s3_requests(sites, extra):
    """The most S3 requests of each class one run can send, retries included."""
    totals = {"put": 0, "get": 0, "free": 0}
    for _, _, _, kind, runs, retry in sites:
        totals[kind] += runs * ATTEMPTS[retry]
    totals["put"] += extra["put"] * CLI_ATTEMPTS
    totals["get"] += extra["get"] * CLI_ATTEMPTS
    return totals


def worst_case(snapshot, expected, run, image_bytes, seed_bytes, model_id, extra, sites, timeline):
    units = {key: Decimal(value) for key, value in snapshot["unit_prices"].items()}
    rate, rate_type = node_rate(snapshot, expected)
    volume_hour = Decimal(snapshot["node_class_volume_gib"]) * units["ebs_gp3_usd_per_gb_month"] \
        / HOURS_PER_MONTH
    model, reports = run["model"], run["reports"]
    # every HTTP send to Bedrock: Strands turns, times its tries per call, times the SDK's;
    # the model turn counts the same number at the Bedrock client itself and refuses one more,
    # and run.sh and the controller each refuse a second model turn in one run
    sends = model["turns"] * model["model_attempts"] * model["sdk_attempts"]
    input_tokens = sends * MODEL_CONTEXT_TOKENS[model_id]
    output_tokens = sends * model["max_tokens"]
    images = sum(image_bytes.values())
    objects = seed_bytes + reports["objects"] * reports["object_max_bytes"]
    requests = s3_requests(sites, extra)
    hours = Decimal(timeline["node"]) / 3600
    terms = {
        "node": hours * (rate + volume_hour),
        "bedrock": (input_tokens * units["bedrock_input_usd_per_million_tokens"]
                    + output_tokens * units["bedrock_output_usd_per_million_tokens"])
        / Decimal(10 ** 6),
        "ecr": images / GB * units["ecr_usd_per_gb_month"] * STORAGE_MONTHS,
        "s3": objects / GB * units["s3_usd_per_gb_month"] * STORAGE_MONTHS
        + requests["put"] * units["s3_put_usd_per_1000"] / 1000
        + requests["get"] * units["s3_get_usd_per_10000"] / 10000,
        # cost_snapshot.build refuses every network path charged per byte or per hour
        "network": Decimal(0),
    }
    total = sum(terms.values())
    return total, terms, {"worst_node_type": rate_type, "node_usd_per_hour": str(rate),
                          "priced_types": len(expected), "bedrock_sends": sends,
                          "input_tokens": input_tokens, "output_tokens": output_tokens,
                          "image_bytes": images, "object_bytes": objects,
                          "s3_requests": requests, "node_hours": str(hours)}


def timeline(section, empty_after):
    """The run's timeline in seconds, from the scripts' own numbers and the NodePools' (above)."""
    budget = source_number(section, "bubblewrap/scripts/clean.sh", r"^CLEAN_BUDGET_S=(\d+)$",
                           "the clean up's time budget")
    lock_wait = source_number(section, "bubblewrap/scripts/deadline.sh", r"^lock_take (\d+) \|\|",
                              "the deadline's lock wait")
    clean_path = lock_wait + budget + LONGEST_CLEAN_CALL_S
    empty_path = ORDINARY_POD_S + empty_after + NODE_REMOVE_S
    return {"run_window": RUN_WINDOW_S, "cleanup_start": CLEANUP_START_S, "clean_path": clean_path,
            "empty_node_path": empty_path, "node": CLEANUP_START_S + max(clean_path, empty_path)}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--snapshot", required=True)
    parser.add_argument("--identity", help="setup.sh's identity, as run-lib.sh identity_now prints it")
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
        section = Path(__file__).resolve().parents[2]
        manifest_size(args.manifest)
        supplier_pod(section / "bubblewrap/deploy/supplier-api-pod.yaml")
        sites, clean_runs = s3_ledger(section)
        run = envelope(args.envelope)
        identity = None
        if args.identity is not None:
            identity = json.loads(args.identity, object_pairs_hook=no_duplicates)
            exact_keys("--identity", identity, {"account", "role", "cluster_arn", "endpoint", "region", "context"})
        try:
            snapshot, fingerprint = cost_snapshot.build(
                args.snapshot, args.account, args.region, args.cluster_name, args.kube_context,
                args.model_id, lambda pools, types: derived_types(
                    {"nodepools": pools, "offered_instance_types": types}), identity)
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
        times = timeline(section, snapshot["empty_node_after_s"])
        total, terms, facts = worst_case(snapshot, expected, run, image_bytes, seed_bytes,
                                         args.model_id, extra, sites, times)
        facts["clean_runs"] = clean_runs
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
                      "snapshot_sha256": fingerprint, "timeline_s": times},
                     sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())

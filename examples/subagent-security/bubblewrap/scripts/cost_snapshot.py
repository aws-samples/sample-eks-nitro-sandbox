"""cost_snapshot.py -- collect the read-only facts the cost check prices, and rebuild them.

  python3 scripts/cost_snapshot.py collect --out <folder> --region <Region> \\
      --cluster-name <cluster> --kube-context <context> --model-id <Bedrock model id>

collect runs a fixed list of read-only AWS CLI and kubectl reads, in a fixed order, and
saves each one's output under <folder>/raw/, with reads.json listing every read's exact
command line and the sha256 of what it saved. setup.sh runs it itself, into the run's own
directory, just before its cost check; run it by hand only to see what a run would read.
<folder> must be new and inside this repository's tmp/; it and everything in it are
readable by you alone. Of the kube context it keeps only the context's name and its
cluster's endpoint, never the credentials a kubeconfig holds. It needs read access to STS,
EKS, ECR (the registry's settings), EC2 (instance types, offerings, route tables, VPC
endpoints, subnets) and the AWS Price List, and to the cluster's RuntimeClasses, NodePools
and NodeClasses.

cost_gate.py rebuilds the snapshot from the raw reads with build() below every time it
runs. build() refuses a folder whose reads are not exactly the list below for this
account, Region, cluster and context (one omitted, added, reordered or with another
command line), whose files do not match their sha256, whose identity, cluster, endpoint,
RuntimeClass, NodePools or NodeClasses do not check out, whose instance-type list is not
the Region's whole list, or whose prices are not exactly one matching Price List record
per item.

Some paths are charged per byte, or per hour, and nothing in this blueprint bounds the
bytes a node sends, so no maximum can be proved for them and build() refuses them rather
than price them: a node-subnet route to anything but the VPC itself, an internet gateway
(for IPv4, from a node with no public address) or a gateway endpoint; any interface or
Gateway Load Balancer endpoint in the VPC; a node subnet or NodeClass that gives a node a
public IPv4 address (a subnet two NodeClasses share counts as public when either does); and
node and control-plane subnets in more than one Availability Zone,
which is every cluster EKS creates today. It also refuses a registry that replicates images
or scans them with Amazon Inspector, a NodePool that would not remove an empty node within
ten minutes (a static-capacity pool with spec.replicas, or a disruption budget of zero in any
spelling, included), and a NodeClass that provisions gp3 IOPS or throughput above the included
baseline.
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path

READS_SCHEMA = "bubblewrap-cost-reads/1"
PRICING_REGION = "us-east-1"  # the AWS Price List API answers here for every Region

# The Price List records each priced item must match, as TERM_MATCH filters. Every record a
# read returns must carry each of these attributes with exactly this value, so a record for
# another item cannot stand in for it.
# shortcut: these attribute names follow the AWS Price List's documented product shape and
# are tested on synthetic records only; a live read that matches no record, or more than
# one, is refused, and the filter is then corrected here.
EC2_FILTERS = {"operatingSystem": "Linux", "tenancy": "Shared", "preInstalledSw": "NA",
               "capacitystatus": "Used"}
UNIT_ITEMS = {
    # key: (service code, filters, the unit the record must state, per how many units)
    "ebs_gp3_usd_per_gb_month": ("AmazonEC2", {"productFamily": "Storage", "volumeApiName": "gp3"},
                                 "GB-Mo", 1),
    "ecr_usd_per_gb_month": ("AmazonECR", {"productFamily": "EC2 Container Registry"}, "GB-Mo", 1),
    "s3_usd_per_gb_month": ("AmazonS3", {"storageClass": "General Purpose", "volumeType": "Standard"},
                            "GB-Mo", 1),
    "s3_put_usd_per_1000": ("AmazonS3", {"group": "S3-API-Tier1"}, "Requests", 1000),
    "s3_get_usd_per_10000": ("AmazonS3", {"group": "S3-API-Tier2"}, "Requests", 10000),
}
# The Bedrock model each id is priced as, in the Price List's own name for it.
BEDROCK_MODELS = {"global.anthropic.claude-sonnet-4-5-20250929-v1:0": "Claude Sonnet 4.5"}
BEDROCK_ITEMS = {"bedrock_input_usd_per_million_tokens": "Input tokens",
                 "bedrock_output_usd_per_million_tokens": "Output tokens"}
TOKEN_UNITS = {"1k tokens": 1000, "1m tokens": 1, "million tokens": 1, "tokens": 10 ** 6}
# A NodePool must remove an empty node within this many seconds of it becoming empty.
EMPTY_NODE_MAX_S = 600
# gp3's included performance; anything above it is billed per IOPS-month and MiB/s-month.
GP3_BASE = {"iops": 3000, "throughput": 125}
# Every route target the EC2 API names. A node-subnet route may use only GatewayId, and only
# for "local", an internet gateway (IPv4 destinations) or a gateway endpoint (prefix lists).
ROUTE_TARGETS = ("GatewayId", "NatGatewayId", "TransitGatewayId", "InstanceId", "NetworkInterfaceId",
                 "VpcPeeringConnectionId", "CarrierGatewayId", "LocalGatewayId", "CoreNetworkArn",
                 "EgressOnlyInternetGatewayId", "OdbNetworkArn")


class Bad(Exception):
    pass


def strict(text, what):
    def pairs(items):
        seen = {}
        for key, value in items:
            if key in seen:
                raise Bad(f"{what} has the key {key!r} twice")
            seen[key] = value
        return seen

    def constant(name):
        raise Bad(f"{what} holds {name}")
    try:
        return json.loads(text, object_pairs_hook=pairs, parse_float=Decimal, parse_constant=constant)
    except ValueError as error:
        raise Bad(f"{what} is not JSON: {error}")


def aws(*args):
    return ["aws", *args, "--output", "json"]


def kube(context, *args):
    return ["kubectl", "--context", context, *args, "-o", "json"]


def pricing(service, filters):
    terms = [f"Type=TERM_MATCH,Field={k},Value={v}" for k, v in sorted(filters.items())]
    return aws("pricing", "get-products", "--region", PRICING_REGION, "--service-code", service,
               "--filters", *terms)


def first_reads(region, cluster, context):
    """The reads that do not depend on any other read, in the order collect runs them."""
    return [
        ("sts", aws("sts", "get-caller-identity", "--region", region)),
        ("cluster", aws("eks", "describe-cluster", "--name", cluster, "--region", region)),
        ("kubeconfig", ["kubectl", "config", "view", "--minify", "--context", context, "-o", "json"]),
        ("ecr_registry", aws("ecr", "describe-registry", "--region", region)),
        ("ecr_scanning", aws("ecr", "get-registry-scanning-configuration", "--region", region)),
        ("runtimeclasses", kube(context, "get", "runtimeclasses")),
        ("nodepools", kube(context, "get", "nodepools.karpenter.sh")),
        ("nodeclasses", kube(context, "get", "nodeclasses.eks.amazonaws.com")),
        ("instance_types", aws("ec2", "describe-instance-types", "--region", region)),
        ("offerings", aws("ec2", "describe-instance-type-offerings", "--location-type", "region",
                          "--region", region)),
    ]


def later_reads(region, model_id, vpc, types):
    """The reads that depend on the first ones: the VPC's network, then every price."""
    if model_id not in BEDROCK_MODELS:
        raise Bad(f"no Price List name is known for the model {model_id!r}")
    reads = [(name, aws("ec2", operation, "--region", region, "--filters", f"Name=vpc-id,Values={vpc}"))
             for name, operation in (("route_tables", "describe-route-tables"),
                                     ("vpc_endpoints", "describe-vpc-endpoints"),
                                     ("subnets", "describe-subnets"))]
    for name in sorted(types):
        reads.append((f"price_ec2_{name}", pricing("AmazonEC2", {
            **EC2_FILTERS, "regionCode": region, "instanceType": name})))
        reads.append((f"price_automode_{name}", pricing("AmazonEKS", {
            "regionCode": region, "instanceType": name, "operation": "EKSAutoUsage"})))
    for key, (service, filters, _, _) in sorted(UNIT_ITEMS.items()):
        reads.append((f"price_{key}", pricing(service, {**filters, "regionCode": region})))
    for key, kind in sorted(BEDROCK_ITEMS.items()):
        reads.append((f"price_{key}", pricing("AmazonBedrock", {
            "regionCode": region, "model": BEDROCK_MODELS[model_id], "inferenceType": kind})))
    return reads


def sha(data):
    return hashlib.sha256(data).hexdigest()


def norm_endpoint(url):
    url = str(url).strip().lower().rstrip("/")
    return url[:-4] if url.endswith(":443") else url


def no_more_pages(raw, what, token="NextToken"):
    if raw.get(token) or (raw.get("metadata") or {}).get("continue"):
        raise Bad(f"the {what} read is one page of several, not the whole list")


def role_of(arn):
    """The IAM role (or user) an STS caller ARN acts as: an assumed role's session is dropped."""
    match = re.fullmatch(r"arn:([a-z-]+):sts::(\d{12}):assumed-role/([^/]+)/.+", str(arn))
    return f"arn:{match.group(1)}:iam::{match.group(2)}:role/{match.group(3)}" if match else str(arn)


def minimal_kubeconfig(view):
    """Of a kubeconfig view, only the context's name and its cluster's endpoint."""
    try:
        return {"clusters": [{"cluster": {"server": c["cluster"]["server"]}} for c in view.get("clusters") or []],
                "contexts": [{"name": c["name"]} for c in view.get("contexts") or []]}
    except (KeyError, TypeError, AttributeError):
        raise Bad("the kubeconfig read has no context name or cluster endpoint")


def target(raws, account, region, cluster, context, identity=None):
    """The exact account, role, Region, cluster ARN and API endpoint the reads were made against."""
    if raws["sts"].get("Account") != account:
        raise Bad(f"the reads were made as another account, not {account}")
    found = raws["cluster"].get("cluster") or {}
    arn = f"arn:aws:eks:{region}:{account}:cluster/{cluster}"
    if found.get("arn") != arn or found.get("name") != cluster:
        raise Bad(f"describe-cluster returned another cluster, not {arn}")
    if (found.get("computeConfig") or {}).get("enabled") is not True:
        raise Bad("the cluster does not use EKS Auto Mode compute")
    endpoint = str(found.get("endpoint", ""))
    view = raws["kubeconfig"]
    if view != minimal_kubeconfig(view):
        raise Bad("the kubeconfig read holds more than the context's name and its cluster's endpoint")
    clusters, contexts = view.get("clusters") or [], view.get("contexts") or []
    if not endpoint.startswith("https://") or len(clusters) != 1 or len(contexts) != 1 or \
            contexts[0].get("name") != context or \
            norm_endpoint(clusters[0].get("cluster", {}).get("server")) != norm_endpoint(endpoint):
        raise Bad(f"the kube context {context} does not point at exactly the described cluster's endpoint")
    if identity is not None:
        found_identity = {"account": account, "role": role_of(raws["sts"].get("Arn")), "cluster_arn": arn,
                          "endpoint": norm_endpoint(endpoint), "region": region, "context": context}
        if dict(identity, endpoint=norm_endpoint(identity.get("endpoint", ""))) != found_identity:
            raise Bad("the reads were not made as the account, role, cluster, endpoint, Region and context "
                      "this run acts through")
    vpc = (found.get("resourcesVpcConfig") or {}).get("vpcId")
    if not isinstance(vpc, str) or not re.fullmatch(r"vpc-[0-9a-f]+", vpc):
        raise Bad("describe-cluster names no VPC")
    return vpc


def seconds(text, what):
    """A Kubernetes duration such as 30s, 5m or 1h30m, in seconds; refuses Never and anything else."""
    match = re.fullmatch(r"(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?", str(text))
    if not text or not match or not any(match.groups()):
        raise Bad(f"{what} is {text!r}, not a duration this check can bound")
    hours, minutes, secs = (int(g or 0) for g in match.groups())
    return hours * 3600 + minutes * 60 + secs


def empties_node(pool):
    """The seconds after which this NodePool removes a node with no workload, or a refusal."""
    name, disruption = pool["name"], pool["disruption"]
    if disruption.get("consolidationPolicy") not in ("WhenEmpty", "WhenEmptyOrUnderutilized"):
        raise Bad(f"NodePool {name} does not consolidate empty nodes")
    after = seconds(disruption.get("consolidateAfter"), f"NodePool {name}'s consolidateAfter")
    if after > EMPTY_NODE_MAX_S:
        raise Bad(f"NodePool {name} waits {after}s before removing an empty node, more than {EMPTY_NODE_MAX_S}s")
    if pool.get("static"):
        raise Bad(f"NodePool {name} sets spec.replicas: a static-capacity pool keeps its nodes and is not "
                  "consolidated, so nothing removes the run's node")
    for budget in disruption.get("budgets") or []:
        # Karpenter reads nodes as a count or a percentage; any spelling of zero (0, 00, 0%, 000%)
        # stops it removing a node, and so does a value this check cannot read
        nodes = re.fullmatch(r"(\d+)%?", str(budget.get("nodes", "10%")).strip())
        if budget.get("schedule") or not nodes or int(nodes.group(1)) == 0:
            raise Bad(f"NodePool {name} has a disruption budget that can stop it removing an empty node")
    return after


def registry(raws):
    """The account's registry must not copy or rescan what this run pushes, at a charge."""
    if ((raws["ecr_registry"].get("replicationConfiguration") or {}).get("rules")) or []:
        raise Bad("the ECR registry replicates images, which charges for each copy")
    scan = (raws["ecr_scanning"].get("scanningConfiguration") or {}).get("scanType")
    if scan != "BASIC":
        raise Bad(f"the ECR registry's scan type is {scan!r}, not BASIC; enhanced scanning charges per image")


def scheduling(raws):
    """Every NodePool, the NodeClass each references, and the RuntimeClass the pod uses."""
    for name in ("runtimeclasses", "nodepools", "nodeclasses"):
        no_more_pages(raws[name], name)
    runtime = [r for r in raws["runtimeclasses"].get("items", [])
               if (r.get("metadata") or {}).get("name") == "isolated-sandbox"]
    if len(runtime) != 1 or runtime[0].get("handler") != "isolated-sandbox":
        raise Bad("there is not exactly one isolated-sandbox RuntimeClass with that handler")
    tolerations = (runtime[0].get("scheduling") or {}).get("tolerations") or []
    classes = {}
    for item in raws["nodeclasses"].get("items", []):
        name = item["metadata"]["name"]
        storage = item.get("spec", {}).get("ephemeralStorage") or {}
        size = re.fullmatch(r"(\d+)Gi", str(storage.get("size")))
        subnets = [s.get("id") for s in (item.get("status") or {}).get("subnets") or []]
        if not size or not subnets or not all(isinstance(s, str) and s.startswith("subnet-") for s in subnets):
            raise Bad(f"NodeClass {name} has no ephemeralStorage.size in Gi or no resolved subnets")
        for key, base in GP3_BASE.items():
            if key in storage and not (str(storage[key]).isdigit() and int(storage[key]) <= base):
                raise Bad(f"NodeClass {name} provisions gp3 {key} {storage[key]!r}, above the included "
                          f"{base}, which this check does not price")
        public = (item.get("spec", {}).get("advancedNetworking") or {}).get("associatePublicIPAddress")
        if public is not None and not isinstance(public, bool):
            raise Bad(f"NodeClass {name} sets associatePublicIPAddress to {public!r}, not true or false")
        classes[name] = (int(size.group(1)), sorted(subnets), public)
    pools = []
    for item in raws["nodepools"].get("items", []):
        spec = item["spec"]["template"]["spec"]
        name = item["metadata"]["name"]
        ref = spec.get("nodeClassRef") or {}
        if ref.get("group") != "eks.amazonaws.com" or ref.get("kind") != "NodeClass" or \
                ref.get("name") not in classes:
            raise Bad(f"NodePool {name} references a NodeClass the read does not hold")
        taints = spec.get("taints") or []
        for taint in taints:
            if any(t.get("operator") == "Exists" and t.get("key") in (None, "", taint.get("key"))
                   or (t.get("key"), t.get("value")) == (taint.get("key"), taint.get("value"))
                   for t in tolerations):
                raise Bad(f"the RuntimeClass tolerates NodePool {name}'s taint, so a pool the "
                          "check treats as closed to the pod could take it")
        pools.append({"name": name, "taints": taints, "requirements": spec.get("requirements") or [],
                      "node_class": ref["name"], "disruption": item["spec"].get("disruption") or {},
                      "static": "replicas" in item["spec"]})
    if not pools:
        raise Bad("the cluster has no NodePool")
    return pools, classes


def offered(raws, region):
    types, offers = raws["instance_types"], raws["offerings"]
    no_more_pages(types, "instance types")
    no_more_pages(offers, "instance type offerings")
    found = {}
    for item in types.get("InstanceTypes") or []:
        name = item["InstanceType"]
        if name in found:
            raise Bad(f"instance type {name} is listed twice")
        found[name] = {"architectures": list(item["ProcessorInfo"]["SupportedArchitectures"])}
    offering = offers.get("InstanceTypeOfferings") or []
    if any(o.get("LocationType") != "region" or o.get("Location") != region for o in offering):
        raise Bad(f"an offering in the read is not a {region} regional offering")
    names = {o["InstanceType"] for o in offering}
    if len(found) < 100 or set(found) != names:
        raise Bad("the instance-type read is not the Region's whole list: it has "
                  f"{len(found)} types, and differs from the offerings by "
                  f"{sorted(names ^ set(found))[:5]}")
    return found


def route_ok(route):
    """Whether a route leads only to the VPC itself, an internet gateway (IPv4) or a gateway endpoint."""
    targets = {key for key in ROUTE_TARGETS if route.get(key)}
    gateway = str(route.get("GatewayId", ""))
    return targets == {"GatewayId"} and (
        gateway == "local"
        or (gateway.startswith("igw-") and bool(route.get("DestinationCidrBlock")))
        or (gateway.startswith("vpce-") and bool(route.get("DestinationPrefixListId"))))


def egress(raws, subnets, public, cluster_subnets):
    """Refuses every node path this check cannot price; the module docstring lists them."""
    for name in ("route_tables", "vpc_endpoints", "subnets"):
        no_more_pages(raws[name], name)
    tables = raws["route_tables"].get("RouteTables") or []
    for subnet in subnets:
        explicit = [t for t in tables if any(a.get("SubnetId") == subnet for a in t.get("Associations") or [])]
        main = [t for t in tables if any(a.get("Main") is True for a in t.get("Associations") or [])]
        chosen = explicit or main
        if len(chosen) != 1:
            raise Bad(f"subnet {subnet} has {len(chosen)} route tables in the read, not one")
        for route in chosen[0].get("Routes") or []:
            if not route_ok(route):
                where = {k: route[k] for k in ROUTE_TARGETS if route.get(k)}
                raise Bad(f"node subnet {subnet} has a route to {where}, a path charged per byte or per hour "
                          "that nothing here bounds, so no maximum can be proved for it")
    for endpoint in raws["vpc_endpoints"].get("VpcEndpoints") or []:
        if endpoint.get("VpcEndpointType") != "Gateway" and endpoint.get("State") not in ("deleted", "rejected"):
            raise Bad(f"the VPC has the {endpoint.get('VpcEndpointType')} endpoint {endpoint.get('VpcEndpointId')}, "
                      "which charges per GB it processes, and nothing here bounds those bytes")
    found = {s.get("SubnetId"): s for s in raws["subnets"].get("Subnets") or []}
    zones = set()
    for subnet in sorted(set(subnets) | set(cluster_subnets)):
        if subnet not in found:
            raise Bad(f"subnet {subnet} is not in the subnet read")
        zones.add(found[subnet].get("AvailabilityZone"))
    for subnet in subnets:
        if public.get(subnet) is True or found[subnet].get("MapCustomerOwnedIpOnLaunch") or \
                (public.get(subnet) is not False and found[subnet].get("MapPublicIpOnLaunch") is not False):
            raise Bad(f"a node in subnet {subnet} gets a public IPv4 address, which is charged per hour and "
                      "opens a path charged per byte")
    if len(zones) != 1 or None in zones:
        raise Bad(f"the node and control-plane subnets are in {len(zones)} Availability Zones; traffic between "
                  "zones is charged per GB and nothing here bounds those bytes")


def products(raw, what, filters):
    no_more_pages(raw, what)
    if set(raw) - {"PriceList", "FormatVersion", "NextToken"} or not isinstance(raw.get("PriceList"), list):
        raise Bad(f"the {what} read is not a get-products output")
    found = [strict(p, f"a {what} record") for p in raw["PriceList"]]
    for product in found:
        attributes = (product.get("product") or {}).get("attributes") or {}
        if any(attributes.get(k) != v for k, v in filters.items()):
            raise Bad(f"a {what} record does not carry every attribute its read asked for")
    return found


def rate(product, what):
    """The one on-demand USD rate of a record, the highest tier if tiered, and its unit."""
    terms = (product.get("terms") or {}).get("OnDemand") or {}
    if len(terms) != 1:
        raise Bad(f"{what} has {len(terms)} on-demand terms, not one")
    dims = list(next(iter(terms.values())).get("priceDimensions", {}).values())
    units = {d.get("unit") for d in dims}
    if not dims or len(units) != 1:
        raise Bad(f"{what} has no price, or mixed units {sorted(map(str, units))}")
    rates = [Decimal(str(d["pricePerUnit"]["USD"])) for d in dims]
    if any(not r.is_finite() or r <= 0 for r in rates):
        raise Bad(f"{what} has a zero, negative or non-finite rate")
    return max(rates), units.pop()


def one(found, what):
    if len(found) != 1:
        raise Bad(f"{len(found)} Price List records for {what}, not exactly one")
    return found[0]


def load(folder):
    reads_path = Path(folder) / "reads.json"
    try:
        data = reads_path.read_bytes()
    except OSError as error:
        raise Bad(f"could not read {reads_path}: {error}")
    return strict(data.decode("utf-8"), "reads.json"), sha(data)


def build(folder, account, region, cluster, context, model_id, derive, identity=None):
    """The snapshot cost_gate.py prices, rebuilt from the raw reads alone.

    derive(nodepools, offered) is cost_gate.derived_types, passed in so the price reads must
    be exactly the set the gate itself will ask for. Returns (snapshot, fingerprint), where
    the fingerprint is the sha256 of reads.json, which holds every raw file's sha256.
    """
    reads, fingerprint = load(folder)
    if set(reads) != {"schema", "captured_at", "region", "cluster_name", "kube_context", "model_id",
                      "reads"} or reads["schema"] != READS_SCHEMA:
        raise Bad("reads.json is not a bubblewrap-cost-reads/1 file")
    if [reads["region"], reads["cluster_name"], reads["kube_context"], reads["model_id"]] != \
            [region, cluster, context, model_id]:
        raise Bad("the reads were collected for another Region, cluster, context or model")
    listed = reads["reads"]
    if not isinstance(listed, list):
        raise Bad("reads.json lists no reads")
    raws = {}

    def check(position, name, argv):
        if position >= len(listed):
            raise Bad(f"the read {name} is missing")
        entry = listed[position]
        if not isinstance(entry, dict) or set(entry) != {"name", "argv", "sha256"} or \
                entry["name"] != name or entry["argv"] != argv:
            raise Bad(f"read {position + 1} is not {name} with the command this check expects")
        path = Path(folder) / "raw" / f"{name}.json"
        try:
            data = path.read_bytes()
        except OSError:
            raise Bad(f"the raw file for {name} is missing")
        if sha(data) != entry["sha256"]:
            raise Bad(f"the raw file for {name} does not match its sha256 in reads.json")
        raws[name] = strict(data.decode("utf-8"), f"the {name} read")
        if not isinstance(raws[name], dict):
            raise Bad(f"the {name} read is not a JSON object")

    plan = first_reads(region, cluster, context)
    for position, (name, argv) in enumerate(plan):
        check(position, name, argv)
    vpc = target(raws, account, region, cluster, context, identity)
    registry(raws)
    pools, classes = scheduling(raws)
    types = offered(raws, region)
    snapshot_pools = [{k: p[k] for k in ("name", "taints", "requirements")} for p in pools]
    derived = derive(snapshot_pools, types)
    later = later_reads(region, model_id, vpc, derived)
    for position, (name, argv) in enumerate(later, start=len(plan)):
        check(position, name, argv)
    if len(listed) != len(plan) + len(later):
        raise Bad(f"reads.json lists {len(listed)} reads, not the {len(plan) + len(later)} expected")
    open_pools = [p for p in pools if not any(t.get("effect") in ("NoSchedule", "NoExecute")
                                              for t in p["taints"])]
    empty_after = max((empties_node(p) for p in open_pools), default=0)
    subnets = sorted({s for p in open_pools for s in classes[p["node_class"]][1]})
    # a subnet two NodeClasses share gets a public address if either assigns one: True wins,
    # then None (the subnet's own default), and False only when every NodeClass says False
    settings = {}
    for pool in open_pools:
        _, nets, setting = classes[pool["node_class"]]
        for subnet in nets:
            settings.setdefault(subnet, set()).add(setting)
    public = {s: True if True in v else None if None in v else False for s, v in settings.items()}
    cluster_subnets = ((raws["cluster"].get("cluster") or {}).get("resourcesVpcConfig") or {}).get("subnetIds")
    if not cluster_subnets:
        raise Bad("describe-cluster names no control-plane subnets")
    egress(raws, subnets, public, cluster_subnets)

    prices = {}
    for name in sorted(derived):
        ec2 = one(products(raws[f"price_ec2_{name}"], f"EC2 {name}",
                           {**EC2_FILTERS, "regionCode": region, "instanceType": name}), f"EC2 {name}")
        fee = one(products(raws[f"price_automode_{name}"], f"Auto Mode {name}",
                           {"regionCode": region, "instanceType": name, "operation": "EKSAutoUsage"}),
                  f"the Auto Mode fee for {name}")
        prices[name] = {}
        for key, record, what in (("ec2_usd_per_hour", ec2, f"EC2 {name}"),
                                  ("auto_mode_usd_per_hour", fee, f"Auto Mode {name}")):
            value, unit = rate(record, what)
            if unit != "Hrs":
                raise Bad(f"{what} is priced per {unit}, not per hour")
            prices[name][key] = value
    units = {}
    for key, (_, filters, want, per) in UNIT_ITEMS.items():
        record = one(products(raws[f"price_{key}"], key, {**filters, "regionCode": region}), key)
        value, unit = rate(record, key)
        if unit != want:
            raise Bad(f"{key} is priced per {unit}, not per {want}")
        units[key] = value * per
    for key, kind in BEDROCK_ITEMS.items():
        found = products(raws[f"price_{key}"], key, {"regionCode": region, "model": BEDROCK_MODELS[model_id],
                                                     "inferenceType": kind})
        if not found:
            raise Bad(f"no Price List record for {key}")
        best = Decimal(0)
        for record in found:  # every matching record, and the highest of them
            value, unit = rate(record, key)
            factor = TOKEN_UNITS.get(str(unit).strip().lower())
            if factor is None:
                raise Bad(f"{key} is priced per {unit!r}, which is not a token unit this check knows")
            best = max(best, value * factor)
        units[key] = best
    volume = max(classes[p["node_class"]][0] for p in open_pools) if open_pools else 0
    return {"captured_at": reads["captured_at"], "nodepools": snapshot_pools, "offered_instance_types": types,
            "node_class_volume_gib": volume, "node_subnets": subnets, "prices": prices,
            "unit_prices": units, "empty_node_after_s": empty_after}, fingerprint


def run_read(argv):
    result = subprocess.run(argv, capture_output=True, timeout=300)
    if result.returncode != 0:
        sys.stderr.write(result.stderr.decode("utf-8", "replace"))
        raise Bad(f"the read {' '.join(argv[:4])} ... failed (exit {result.returncode}); collected nothing")
    return result.stdout


def private_folder(path):
    """A new folder inside the repository's tmp/, and not outside it through a link, mode 0700."""
    tmp = Path(__file__).resolve().parents[4] / "tmp"
    given = Path(os.path.abspath(path))
    out = Path(os.path.realpath(given.parent)) / given.name
    if tmp not in out.parents:
        raise Bad(f"{path} must be a new folder inside {tmp}")
    if os.path.lexists(out):
        raise Bad(f"{out} already exists; collect into a new folder")
    out.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    out.mkdir(mode=0o700)
    (out / "raw").mkdir(mode=0o700)
    return out


def write_private(path, data):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(data)


def collect(args):
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import cost_gate
    os.umask(0o077)
    out = private_folder(args.out)
    listed, raws = [], {}

    def save(name, argv):
        data = run_read(argv)
        if name == "kubeconfig":  # the context's name and endpoint, never its credentials
            data = json.dumps(minimal_kubeconfig(strict(data.decode("utf-8"), "the kubeconfig read")),
                              indent=1, sort_keys=True).encode()
        write_private(out / "raw" / f"{name}.json", data)
        listed.append({"name": name, "argv": argv, "sha256": sha(data)})
        raws[name] = strict(data.decode("utf-8"), f"the {name} read")

    captured = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    for name, argv in first_reads(args.region, args.cluster_name, args.kube_context):
        save(name, argv)
    vpc = (raws["cluster"].get("cluster") or {}).get("resourcesVpcConfig", {}).get("vpcId")
    pools, _ = scheduling(raws)
    types = offered(raws, args.region)
    derived = cost_gate.derived_types({"nodepools": [{k: p[k] for k in ("name", "taints", "requirements")}
                                                     for p in pools], "offered_instance_types": types})
    for name, argv in later_reads(args.region, args.model_id, vpc, derived):
        save(name, argv)
    write_private(out / "reads.json", (json.dumps({
        "schema": READS_SCHEMA, "captured_at": captured, "region": args.region,
        "cluster_name": args.cluster_name, "kube_context": args.kube_context,
        "model_id": args.model_id, "reads": listed}, indent=1, sort_keys=True) + "\n").encode())
    print(f"collected {len(listed)} reads into {out}")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    one_cmd = sub.add_parser("collect", help="run the read-only reads and save them")
    for flag in ("--out", "--region", "--cluster-name", "--kube-context", "--model-id"):
        one_cmd.add_argument(flag, required=True)
    args = parser.parse_args(argv)
    try:
        collect(args)
    except Bad as error:
        print(f"cost snapshot: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

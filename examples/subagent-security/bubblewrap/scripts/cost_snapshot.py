"""cost_snapshot.py -- collect the read-only facts the cost check prices, and rebuild them.

  python3 scripts/cost_snapshot.py collect --out <folder> --region <Region> \\
      --cluster-name <cluster> --kube-context <context> --model-id <Bedrock model id>

collect runs a fixed list of read-only AWS CLI and kubectl reads, in a fixed order, and
saves each one's output unchanged under <folder>/raw/, with reads.json listing every read's
exact command line and the sha256 of what it printed. Set COST_SNAPSHOT in .env to the
folder. It needs read access to STS, EKS, EC2 (instance types, offerings, route tables) and
the AWS Price List, and to the cluster's RuntimeClasses, NodePools, NodeClasses and NodeClaims.

Nothing in the folder is typed by hand, and nothing is trusted because the folder says so:
cost_gate.py rebuilds the snapshot from the raw reads with build() below every time it
runs. build() refuses a folder whose reads are not exactly the list below for this
account, Region, cluster and context (one omitted, added, reordered or with another
command line), whose files do not match their sha256, whose cluster, endpoint, RuntimeClass,
NodePools or NodeClasses do not check out, whose instance-type list is not the Region's
whole list, or whose prices are not exactly one matching Price List record per item.

It also reads the route tables of every subnet the node can use. A node subnet that routes
through a NAT gateway is refused: NAT processing is charged per byte, and nothing in this
blueprint bounds the bytes a node sends, so no maximum can be proved for that path.
"""
import argparse
import hashlib
import json
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
        ("runtimeclasses", kube(context, "get", "runtimeclasses")),
        ("nodepools", kube(context, "get", "nodepools.karpenter.sh")),
        ("nodeclasses", kube(context, "get", "nodeclasses.eks.amazonaws.com")),
        ("instance_types", aws("ec2", "describe-instance-types", "--region", region)),
        ("offerings", aws("ec2", "describe-instance-type-offerings", "--location-type", "region",
                          "--region", region)),
    ]


def later_reads(region, model_id, vpc, types):
    """The reads that depend on the first ones: the VPC's route tables, then every price."""
    if model_id not in BEDROCK_MODELS:
        raise Bad(f"no Price List name is known for the model {model_id!r}")
    reads = [("route_tables", aws("ec2", "describe-route-tables", "--region", region,
                                  "--filters", f"Name=vpc-id,Values={vpc}"))]
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


def target(raws, account, region, cluster, context):
    """The exact account, Region, cluster ARN and API endpoint the reads were made against."""
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
    clusters, contexts = view.get("clusters") or [], view.get("contexts") or []
    if not endpoint.startswith("https://") or len(clusters) != 1 or len(contexts) != 1 or \
            contexts[0].get("name") != context or \
            norm_endpoint(clusters[0].get("cluster", {}).get("server")) != norm_endpoint(endpoint):
        raise Bad(f"the kube context {context} does not point at exactly the described cluster's endpoint")
    vpc = (found.get("resourcesVpcConfig") or {}).get("vpcId")
    if not isinstance(vpc, str) or not re.fullmatch(r"vpc-[0-9a-f]+", vpc):
        raise Bad("describe-cluster names no VPC")
    return vpc


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
        size = re.fullmatch(r"(\d+)Gi", str((item.get("spec", {}).get("ephemeralStorage") or {}).get("size")))
        subnets = [s.get("id") for s in (item.get("status") or {}).get("subnets") or []]
        if not size or not subnets or not all(isinstance(s, str) and s.startswith("subnet-") for s in subnets):
            raise Bad(f"NodeClass {name} has no ephemeralStorage.size in Gi or no resolved subnets")
        classes[name] = (int(size.group(1)), sorted(subnets))
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
                      "node_class": ref["name"]})
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


def nat_free(raw, subnets):
    """Each node subnet's route table, and a refusal if any of them routes through NAT."""
    no_more_pages(raw, "route tables")
    tables = raw.get("RouteTables") or []
    for subnet in subnets:
        explicit = [t for t in tables if any(a.get("SubnetId") == subnet for a in t.get("Associations") or [])]
        main = [t for t in tables if any(a.get("Main") is True for a in t.get("Associations") or [])]
        chosen = explicit or main
        if len(chosen) != 1:
            raise Bad(f"subnet {subnet} has {len(chosen)} route tables in the read, not one")
        nat = [r.get("NatGatewayId") for r in chosen[0].get("Routes") or [] if r.get("NatGatewayId")]
        if nat:
            raise Bad(f"node subnet {subnet} routes through NAT gateway {nat[0]}; NAT processing is "
                      "charged per byte and nothing bounds the bytes a node sends, so no maximum can "
                      "be proved for this path")


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


def build(folder, account, region, cluster, context, model_id, derive):
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
    vpc = target(raws, account, region, cluster, context)
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
    subnets = sorted({s for p in open_pools for s in classes[p["node_class"]][1]})
    nat_free(raws["route_tables"], subnets)

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
            "unit_prices": units}, fingerprint


def run_read(argv):
    result = subprocess.run(argv, capture_output=True, timeout=300)
    if result.returncode != 0:
        sys.stderr.write(result.stderr.decode("utf-8", "replace"))
        raise Bad(f"the read {' '.join(argv[:4])} ... failed (exit {result.returncode}); collected nothing")
    return result.stdout


def collect(args):
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import cost_gate
    out = Path(args.out)
    if out.exists():
        raise Bad(f"{out} already exists; collect into a new folder")
    (out / "raw").mkdir(parents=True)
    listed, raws = [], {}

    def save(name, argv):
        data = run_read(argv)
        (out / "raw" / f"{name}.json").write_bytes(data)
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
    (out / "reads.json").write_text(json.dumps({
        "schema": READS_SCHEMA, "captured_at": captured, "region": args.region,
        "cluster_name": args.cluster_name, "kube_context": args.kube_context,
        "model_id": args.model_id, "reads": listed}, indent=1, sort_keys=True) + "\n")
    print(f"collected {len(listed)} reads into {out}; set COST_SNAPSHOT={out} in .env")


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

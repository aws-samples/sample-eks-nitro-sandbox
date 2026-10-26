"""The procurement analyst's deterministic facts, shared by every Subagent security sample.

Nothing here knows which confinement layer is in use. The comparison and the two gates are
the same whether the tool roles run under nono, bubblewrap or OpenShell, so all three
samples import this module unchanged and compare their model's answer with the same
arithmetic.

The gates are deliberately separate:

  compare()                 qualifies suppliers from the case facts and the availability
                            lookup, and names the cheapest eligible one. Price alone cannot
                            win: a supplier is only eligible once it meets every
                            requirement, so a cheap late bid loses.
  report_choice_matches()   checks the model's own explicit choice against that winner.
                            It reads the recommended_supplier field and nothing else, so a
                            supplier name that appears only in the prose or in a citation
                            cannot satisfy it.
  report_cites_sources()    checks that every original source key is cited in the prose.
"""
import json
from pathlib import Path

CASE = "rfp-001"

# Where the image puts the shared fixtures. The supplier API reads the same path.
FIXTURES = Path("/opt/analyst/fixtures")
FIXTURE = FIXTURES / "case.json"
AVAILABILITY_FIXTURE = FIXTURES / "availability.json"

# The commercial terms the deterministic comparison reads. A proposal document carries
# these under "terms"; the case carries them on the supplier entry.
TERMS = ("price_usd", "delivery_days", "warranty_months")


def load_json(path):
    return json.loads(Path(path).read_text())


def compare(case: dict, availability: dict) -> dict:
    """Qualify suppliers against the case requirements, then pick the cheapest eligible one.

    availability maps a supplier id to a record with an "available" flag, as the supplier
    API serves it. A supplier missing from the lookup is treated as unavailable rather
    than as eligible, so a short reply from the API cannot widen the field.
    """
    requirements = case["requirements"]
    rows = []
    for supplier in case["suppliers"]:
        failures = []
        if supplier["price_usd"] > requirements["budget_usd"]:
            failures.append("over budget")
        if supplier["delivery_days"] > requirements["max_delivery_days"]:
            failures.append("late delivery")
        if supplier["warranty_months"] < requirements["min_warranty_months"]:
            failures.append("insufficient warranty")
        if not availability.get(supplier["id"], {}).get("available"):
            failures.append("unavailable")
        rows.append({**supplier, "failures": failures, "eligible": not failures})
    eligible = [row for row in rows if row["eligible"]]
    winner = min(eligible, key=lambda row: row["price_usd"])["id"] if eligible else None
    return {"case_id": case["case_id"], "recommended_supplier": winner, "suppliers": rows}


def availability_from_reply(reply: dict) -> dict:
    """The availability map out of the supplier API's reply to GET /cases/<case>/suppliers.

    The API answers {"case_id": ..., "availability": {...}} so that a reader can tell which
    case a lookup was for, while compare() takes the inner map. Every Subagent security
    sample unwraps it here rather than in its own controller, so the three cannot drift
    apart on the shape.

    It raises instead of returning an empty map on anything unexpected. compare() treats a
    supplier missing from the lookup as unavailable, which is what stops a short reply from
    widening the field -- but it means an envelope passed in whole would mark every supplier
    unavailable and simply name no winner. That reads as "no supplier qualifies" rather than
    as a broken lookup, so the shape is checked here where it can still fail loudly.
    """
    if not isinstance(reply, dict):
        raise ValueError(f"the supplier availability reply is not an object: {reply!r}")
    availability = reply.get("availability")
    if not isinstance(availability, dict) or not availability:
        raise ValueError(
            "the supplier availability reply carries no non-empty 'availability' map: "
            f"{reply!r}")
    # The records themselves are checked, not just the map around them. A dict is not
    # enough: an envelope wrapped a second time would pass that and hand compare() a map
    # whose keys are "case_id" and "availability", which is the same silent "no supplier
    # qualifies" one level further in. Every value has to carry the flag compare() reads.
    #
    # The flag has to be a real boolean, not merely present. compare() reads its
    # truthiness, and the dangerous direction is a truthy non-boolean: the string "false",
    # like any non-empty string, is truthy in Python, so a reply carrying
    # {"available": "false"} would qualify a supplier the lookup meant to exclude. That is
    # worse than the envelope bug this function was added for, because it changes the
    # answer rather than emptying it.
    malformed = sorted(
        key for key, record in availability.items()
        if not isinstance(record, dict) or type(record.get("available")) is not bool)
    if malformed:
        raise ValueError(
            "the supplier availability reply has no boolean 'available' flag for "
            f"{malformed}, so it is not an availability map: {reply!r}")
    return availability


def proposal_matches_case(proposal: dict, entry: dict) -> bool:
    """Check one downloaded proposal document against the case's own supplier entry.

    The controller reads each proposal from S3 rather than trusting the copy baked into
    the image, so this is what ties the comparison to the cited originals.
    """
    if not isinstance(proposal, dict) or proposal.get("id") != entry["id"]:
        return False
    if proposal.get("name") != entry["name"]:
        return False
    terms = proposal.get("terms")
    if not isinstance(terms, dict):
        return False
    return all(terms.get(field) == entry[field] for field in TERMS)


def report_choice_matches(payload, expected_supplier) -> bool:
    """Check the model's explicit choice, independently of any name in its prose.

    Reads payload["recommended_supplier"] only. A report whose analysis mentions the right
    supplier while its choice field names another one fails here.
    """
    return (isinstance(payload, dict)
            and isinstance(expected_supplier, str) and bool(expected_supplier)
            and payload.get("recommended_supplier") == expected_supplier
            and isinstance(payload.get("analysis_markdown"), str)
            and bool(payload["analysis_markdown"].strip()))


def report_cites_sources(payload, case: dict) -> bool:
    """Check that the prose cites every original proposal's S3 key."""
    if not isinstance(payload, dict) or not isinstance(payload.get("analysis_markdown"), str):
        return False
    prose = payload["analysis_markdown"]
    return all(supplier["source"] in prose for supplier in case["suppliers"])


def render_report(payload, case: dict) -> str:
    """Render the accepted recommendation.

    The heading comes from the checked recommended_supplier field, not from the prose, so
    the page's headline claim and the gate read the same value.
    """
    chosen = next(s for s in case["suppliers"] if s["id"] == payload["recommended_supplier"])
    return ("# Procurement recommendation\n\n"
            f"**Case:** {case['case_id']}, {case['description']}\n\n"
            f"**Recommended supplier:** {chosen['name']} (`{chosen['id']}`)\n\n"
            f"{payload['analysis_markdown']}\n")

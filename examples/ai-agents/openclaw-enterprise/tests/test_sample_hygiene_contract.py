"""Repository hygiene the sample keeps: its figures, its text, its validation database probes and its jq argv.

The sample's files, figure sources and ASH suppression reasons carry no notes of how the sample was built. A
comment states the rule the code or test enforces, or points at a source a reader has: the README, issue #133,
or the pinned upstream path and version.
"""

from __future__ import annotations

import pathlib
import re

import yaml

SAMPLE = pathlib.Path(__file__).resolve().parents[1]
REPO = SAMPLE.parents[2]
SAMPLE_PATH = SAMPLE.relative_to(REPO).as_posix()
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
# Git-ignored local files (see .gitignore).
SKIP_NAMES = {".env", ".pytest_cache", "__pycache__"}

# Each pattern is built from fragments so that this file does not match itself.
TOKENS = re.compile(
    "|".join(
        [
            "(?i:con" + "ductor)",
            r"(?i:test[ _-]" + "lane)",
            r"(?i:\brul" + r"(?:ing|ed)\b)",
            r"(?<![\d:])\d\d:\d\d" + r"Z\b",  # a clock time without seconds (timestamps keep them)
            "inter" + r"face-r\d",
            r"\br[2-9]" + r"(?=[ ,;)'\"]|$)",  # a revision label; instance names such as r5.large do not match
            r"\bD" + r"1\b",
            r"\bF\d{1,2}" + r"\b",
            r"(?i:clean" + r"up[ -]spec)",
            "(?i:adden" + "dum)",
            r"\b[Oo]ption" + r" E\b",
            r"\bR-Q" + r"P\d",
            r"\bS" + r"C \d",  # a section of a design that is not in the repository
            "cni-port" + "-check",
            "exec " + "decision",
            "design " + "section",
            r"(?i:\brun" + r"book\b)",
            r"\bO" + r"54\b",
            r"\b(?:on|at) " + r"(?=[0-9a-f]*[a-f])(?=[0-9a-f]*\d)[0-9a-f]{7,40}\b",  # a commit of no tracked history
        ]
    ),
    re.MULTILINE,
)
FIGURES = (
    ("1", "openclaw-enterprise-architecture"),
    ("2", "openclaw-enterprise-model-request"),
    ("3", "openclaw-enterprise-pod-admission"),
)
# Every jq --argjson value in the scripts: a boolean, a port or a version number, never a whole API object.
ARGJSON_SITES = {
    ("manage-image-build-stack.sh", "receiptVersion", "receipt_version"),
    ("oce-api-tunnel.sh", "relayPort", "RELAY_PORT"),
    ("oce-api-tunnel.sh", "apiPort", "API_PORT"),
    ("setup-agentgateway-pod-identity.sh", "namespace_created", "namespace_created"),
    ("setup-agentgateway-pod-identity.sh", "account_created", "service_account_created"),
    (
        "setup-agentgateway-pod-identity.sh",
        "region_config_map_created",
        "region_config_map_created",
    ),
    ("setup-agentgateway-pod-identity.sh", "role_created", "role_created"),
    ("setup-agentgateway-pod-identity.sh", "policy_created", "policy_created"),
    ("setup-agentgateway-pod-identity.sh", "association_created", "association_created"),
    ("setup-storage-class.sh", "created", "created"),
}
ARGJSON = re.compile(r'--argjson\s+(\w+)\s+"\$\{?(\w+)\}?"')
API_READ = re.compile(r'\$\(\s*(?:"\$\{(?:KUBECTL|AWS)\[@\]\}"|kubectl\b|aws\b|kube\b)')


def _sample_files() -> list[pathlib.Path]:
    return [
        path
        for path in sorted(SAMPLE.rglob("*"))
        if path.is_file() and not SKIP_NAMES & set(path.relative_to(SAMPLE).parts)
    ]


def _hits(text: str) -> list[str]:
    return [f"{text.count(chr(10), 0, m.start()) + 1}: {m.group(0)}" for m in TOKENS.finditer(text)]


def test_readme_figures_have_captions_alt_text_and_editable_sources() -> None:
    readme = (SAMPLE / "README.md").read_text(encoding="utf-8")
    images = sorted(path.name for path in (SAMPLE / "images").iterdir())

    assert images == sorted(
        f"{name}.{suffix}" for _, name in FIGURES for suffix in ("drawio", "png")
    )
    assert re.findall(r"^\*Figure (\d+): ", readme, re.MULTILINE) == [n for n, _ in FIGURES]
    positions = []
    for number, name in FIGURES:
        caption = readme.index(f"*Figure {number}: ")
        figure = re.search(rf"^!\[([^\]]+)\]\(images/{name}\.png\)$", readme[caption:], re.MULTILINE)
        assert figure is not None, name
        # The image follows its caption paragraph, and its alt text describes it in a sentence.
        assert readme[caption:caption + figure.start()].count("\n\n") == 1, name
        assert len(figure.group(1).split()) >= 10 and figure.group(1).endswith("."), name
        assert (SAMPLE / "images" / f"{name}.png").read_bytes().startswith(PNG_SIGNATURE)
        assert f"(images/{name}.drawio)" in readme, name
        positions.append(caption)
    assert positions == sorted(positions)


def test_sample_files_carry_no_process_references() -> None:
    found = {}
    checked = 0
    for path in _sample_files():
        if path.suffix == ".png":
            assert path.read_bytes().startswith(PNG_SIGNATURE), path
            continue
        text = path.read_text(encoding="utf-8")  # every other file is text
        checked += 1
        if hits := _hits(text):
            found[path.relative_to(SAMPLE).as_posix()] = hits
    assert checked > 40
    assert found == {}


def test_figure_sources_hold_no_comments() -> None:
    sources = sorted((SAMPLE / "images").glob("*.drawio"))

    assert len(sources) == len(FIGURES)
    for source in sources:
        assert "<!--" not in source.read_text(encoding="utf-8"), source.name


def test_sample_ash_suppressions_carry_no_process_references() -> None:
    suppressions = yaml.safe_load((REPO / ".ash" / ".ash.yaml").read_text(encoding="utf-8"))[
        "global_settings"
    ]["suppressions"]
    mine = [entry for entry in suppressions if str(entry.get("path", "")).startswith(SAMPLE_PATH + "/")]
    assert len(mine) > 30
    found = {
        f"{entry['path']}:{entry.get('line_start', '')}": _hits(str(entry.get("reason", "")))
        for entry in mine
    }
    assert {key: hits for key, hits in found.items() if hits} == {}


def test_the_patterns_find_each_kind_of_reference() -> None:
    samples = [
        "a " + "con" + "ductor note",
        "the test" + " lane found it",
        "the 23" + ":09Z rul" + "ing",
        "inter" + "face-r" + "3",
        "design r" + "6 5.1b",
        "D" + "1 section 12",
        "F" + "8: a failed read",
        "clean" + "up spec 619",
        "option" + " E adden" + "dum 3.2",
        "the run" + "book's claim",
        "fails on " + "2ad22eb",
        "Opt" + "ion E: the one policy",
        "the R-Q" + "P2 turn",
        "S" + "C 5.3 step 1",
    ]
    assert [sample for sample in samples if not TOKENS.search(sample)] == []
    data = ["2026-11-19T01:00:00Z", "r5.large", "sha256:" + "d1" * 32, "convergence window", "test_f8_name"]
    assert [sample for sample in data if TOKENS.search(sample)] == []


def test_validation_database_probes_use_pg_isready() -> None:
    documents = list(yaml.safe_load_all((SAMPLE / "deploy" / "oce-validation-postgres.yaml").read_text()))
    deployment = next(document for document in documents if document["kind"] == "Deployment")
    postgres = deployment["spec"]["template"]["spec"]["containers"][0]
    command = ["pg_isready", "-U", "oce_validation", "-d", "openclaw"]

    assert postgres["readinessProbe"] == {
        "exec": {"command": command},
        "initialDelaySeconds": 3,
        "periodSeconds": 3,
        "timeoutSeconds": 2,
        "failureThreshold": 20,
    }
    assert postgres["livenessProbe"] == {
        "exec": {"command": command},
        "initialDelaySeconds": 15,
        "periodSeconds": 10,
        "timeoutSeconds": 2,
        "failureThreshold": 6,
    }


def test_jq_argjson_carries_only_scalars() -> None:
    sites = set()
    for path in sorted((SAMPLE / "scripts").glob("*.sh")):
        source = path.read_text(encoding="utf-8")
        for name, variable in ARGJSON.findall(source):
            sites.add((path.name, name, variable))
            # A value read straight from the Kubernetes or AWS API would put a whole object on argv.
            assignments = re.findall(
                rf"^\s*(?:local\s+)?{variable}=(.*)$", source, re.MULTILINE
            )
            assert assignments, (path.name, variable)
            assert not [value for value in assignments if API_READ.search(value)], (
                path.name,
                variable,
            )
    total = sum(
        path.read_text(encoding="utf-8").count("--argjson")
        for path in (SAMPLE / "scripts").glob("*.sh")
    )

    assert sites == ARGJSON_SITES
    assert total == len(ARGJSON_SITES)

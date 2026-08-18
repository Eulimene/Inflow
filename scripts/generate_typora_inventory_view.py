#!/usr/bin/env python3
"""Validate the Typora inventory contract and generate its Markdown view."""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from copy import deepcopy
from pathlib import Path
from typing import Any
from urllib.parse import urlparse


ROOT = Path(__file__).resolve().parents[1]
PRODUCT_DIR = ROOT / "docs" / "product"
INVENTORY_PATH = PRODUCT_DIR / "TYPORA_CAPABILITY_INVENTORY.json"
SCHEMA_PATH = PRODUCT_DIR / "TYPORA_CAPABILITY_INVENTORY.schema.json"
PRD_PATH = PRODUCT_DIR / "PRD.md"
BENCHMARK_PATH = PRODUCT_DIR / "TYPORA_BENCHMARK.md"
VIEW_PATH = PRODUCT_DIR / "TYPORA_CAPABILITY_INVENTORY.md"

FEATURE_ID_RE = re.compile(
    r"^- \*\*(INF-P[0-3]-[A-Z]+-[0-9]{3})\*\*", re.MULTILINE
)
SHA256_RE = re.compile(r"^[a-f0-9]{64}$")
BENCHMARK_CAPABILITY_RE = re.compile(
    r"`([a-z][a-z0-9-]*(?:\.[a-z][a-z0-9-]*)+)`"
)
BENCHMARK_COVERAGE_START = "<!-- inventory-capability-coverage:start -->"
BENCHMARK_COVERAGE_END = "<!-- inventory-capability-coverage:end -->"


class ContractError(RuntimeError):
    """Raised when the machine inventory violates a cross-field contract."""


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ContractError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_json(path: Path) -> dict[str, Any]:
    try:
        with path.open("r", encoding="utf-8") as handle:
            value = json.load(handle, object_pairs_hook=_reject_duplicate_keys)
    except (OSError, json.JSONDecodeError) as error:
        raise ContractError(f"cannot parse {path.relative_to(ROOT)}: {error}") from error
    if not isinstance(value, dict):
        raise ContractError(f"{path.relative_to(ROOT)} must contain a JSON object")
    return value


def _duplicates(values: list[str]) -> list[str]:
    return sorted(value for value, count in Counter(values).items() if count > 1)


def _require_nonempty_string(value: Any, label: str) -> None:
    if not isinstance(value, str) or not value.strip():
        raise ContractError(f"{label} must be a non-empty string")


def _validate_registry_entry(
    entry: dict[str, Any], id_key: str, expected_prefix: str
) -> None:
    evidence_id = entry.get(id_key)
    _require_nonempty_string(evidence_id, id_key)
    if not evidence_id.startswith(expected_prefix):
        raise ContractError(f"{id_key} {evidence_id!r} must start with {expected_prefix}")

    sha256 = entry.get("sha256")
    if not isinstance(sha256, str) or not SHA256_RE.fullmatch(sha256):
        raise ContractError(f"{evidence_id}: sha256 must be 64 lowercase hex characters")
    if sha256 == "0" * 64:
        raise ContractError(f"{evidence_id}: all-zero sha256 is forbidden")

    if entry.get("result") not in {"passed", "failed", "pending"}:
        raise ContractError(f"{evidence_id}: invalid evidence result")
    _require_nonempty_string(entry.get("artifactURI"), f"{evidence_id}.artifactURI")
    _require_nonempty_string(entry.get("capturedDate"), f"{evidence_id}.capturedDate")
    _require_nonempty_string(entry.get("owner"), f"{evidence_id}.owner")

    environment = entry.get("environment")
    if not isinstance(environment, dict):
        raise ContractError(f"{evidence_id}: environment must be an object")
    for key in ("os", "architecture", "typoraBuild", "settingsProfile", "locale"):
        _require_nonempty_string(environment.get(key), f"{evidence_id}.environment.{key}")


def _validate_evidence_environment(
    capability: dict[str, Any], evidence: dict[str, Any], evidence_kind: str
) -> None:
    capability_id = capability["capabilityID"]
    environment = evidence["environment"]
    platform = capability["typoraPlatform"]
    for key in ("os", "architecture"):
        if environment.get(key) != platform.get(key):
            raise ContractError(
                f"{capability_id}: {evidence_kind} {key} mismatch; "
                f"expected {platform.get(key)!r}, got {environment.get(key)!r}"
            )
    if environment["typoraBuild"] != capability["typoraBuild"]:
        raise ContractError(f"{capability_id}: {evidence_kind} build mismatch")
    if environment["settingsProfile"] != capability["settingsProfile"]:
        raise ContractError(f"{capability_id}: {evidence_kind} settings mismatch")


def validate_contract(
    inventory: dict[str, Any], schema: dict[str, Any], prd: str, benchmark: str
) -> None:
    schema_properties = schema.get("properties")
    schema_required = schema.get("required")
    if not isinstance(schema_properties, dict) or not isinstance(schema_required, list):
        raise ContractError("inventory schema lacks top-level properties/required")
    unknown_top_level = sorted(set(inventory) - set(schema_properties))
    missing_top_level = sorted(set(schema_required) - set(inventory))
    if unknown_top_level or missing_top_level:
        raise ContractError(
            "inventory top-level shape mismatch; "
            f"unknown={unknown_top_level}, missing={missing_top_level}"
        )
    expected_schema_ref = schema_properties.get("$schema", {}).get("const")
    if inventory.get("$schema") != expected_schema_ref:
        raise ContractError("inventory.$schema must reference the checked-in local schema")
    if inventory.get("schemaVersion") != 2:
        raise ContractError("inventory.schemaVersion must be 2")
    if schema_properties.get("schemaVersion", {}).get("const") != 2:
        raise ContractError("schema and inventory schemaVersion disagree")
    if inventory.get("sourceOfTruth") is not True:
        raise ContractError("inventory.sourceOfTruth must be true")
    inventory_statuses = schema_properties.get("inventoryStatus", {}).get("enum")
    if not isinstance(inventory_statuses, list) or inventory.get(
        "inventoryStatus"
    ) not in set(inventory_statuses):
        raise ContractError("inventory.inventoryStatus is not allowed by the schema")

    feature_ids = [
        requirement_id
        for requirement_id in FEATURE_ID_RE.findall(prd)
        if "-DOD-" not in requirement_id
    ]
    duplicate_features = _duplicates(feature_ids)
    if duplicate_features:
        raise ContractError(f"duplicate PRD feature definitions: {duplicate_features}")
    prd_feature_ids = set(feature_ids)
    if not prd_feature_ids:
        raise ContractError("no PRD P0-P3 feature IDs found")

    capabilities = inventory.get("capabilities")
    if not isinstance(capabilities, list) or not capabilities:
        raise ContractError("capabilities must be a non-empty array")
    capability_ids = [capability.get("capabilityID") for capability in capabilities]
    if any(not isinstance(value, str) for value in capability_ids):
        raise ContractError("every capability must have a string capabilityID")
    duplicate_capabilities = _duplicates(capability_ids)
    if duplicate_capabilities:
        raise ContractError(f"duplicate capability IDs: {duplicate_capabilities}")
    capability_by_id = {
        capability["capabilityID"]: capability for capability in capabilities
    }
    if (
        BENCHMARK_COVERAGE_START not in benchmark
        or BENCHMARK_COVERAGE_END not in benchmark
    ):
        raise ContractError("Benchmark machine capability coverage markers are missing")
    benchmark_section = benchmark.split(BENCHMARK_COVERAGE_START, 1)[1].split(
        BENCHMARK_COVERAGE_END, 1
    )[0]
    benchmark_refs = set(BENCHMARK_CAPABILITY_RE.findall(benchmark_section))
    missing_benchmark_refs = sorted(set(capability_ids) - benchmark_refs)
    unknown_benchmark_refs = sorted(benchmark_refs - set(capability_ids))
    if missing_benchmark_refs or unknown_benchmark_refs:
        raise ContractError(
            "Benchmark capability coverage mismatch; "
            f"missing={missing_benchmark_refs}, unknown={unknown_benchmark_refs}"
        )
    capability_schema = schema.get("$defs", {}).get("capability", {})
    capability_properties = capability_schema.get("properties", {})
    allowed_categories = capability_properties.get("category", {}).get("enum")
    allowed_statuses = capability_properties.get("status", {}).get("enum")
    if not isinstance(allowed_categories, list) or not isinstance(
        allowed_statuses, list
    ):
        raise ContractError("inventory schema lacks capability category/status enums")
    for capability in capabilities:
        capability_id = capability["capabilityID"]
        if capability.get("category") not in set(allowed_categories):
            raise ContractError(f"{capability_id}: invalid capability category")
        if capability.get("status") not in set(allowed_statuses):
            raise ContractError(f"{capability_id}: invalid capability status")

    if inventory["inventoryStatus"] == "frozen":
        unfinished = sorted(
            capability["capabilityID"]
            for capability in capabilities
            if capability.get("status") not in {"aligned", "exception"}
        )
        if unfinished:
            raise ContractError(
                "frozen inventory has non-aligned/non-exception capabilities: "
                f"{unfinished}"
            )

    coverage = inventory.get("coverage")
    if not isinstance(coverage, dict):
        raise ContractError("coverage must be an object")
    capability_refs = coverage.get("capabilityRefs")
    exclusions = coverage.get("exclusions")
    if not isinstance(capability_refs, list) or not isinstance(exclusions, list):
        raise ContractError("coverage arrays are missing")

    mapped_ids = [entry.get("requirementID") for entry in capability_refs]
    excluded_ids = [entry.get("requirementID") for entry in exclusions]
    duplicate_mapped = _duplicates(mapped_ids)
    duplicate_excluded = _duplicates(excluded_ids)
    if duplicate_mapped:
        raise ContractError(f"requirements mapped more than once: {duplicate_mapped}")
    if duplicate_excluded:
        raise ContractError(f"requirements excluded more than once: {duplicate_excluded}")
    overlap = sorted(set(mapped_ids) & set(excluded_ids))
    if overlap:
        raise ContractError(f"requirements both mapped and excluded: {overlap}")

    covered_ids = set(mapped_ids) | set(excluded_ids)
    missing = sorted(prd_feature_ids - covered_ids)
    unknown = sorted(covered_ids - prd_feature_ids)
    if missing or unknown:
        raise ContractError(
            f"closed-world coverage mismatch; missing={missing}, unknown={unknown}"
        )

    referenced_capability_ids: list[str] = []
    for entry in capability_refs:
        requirement_id = entry.get("requirementID")
        refs = entry.get("capabilityIDs")
        if not isinstance(refs, list) or not refs:
            raise ContractError(f"{requirement_id}: capabilityIDs must be non-empty")
        if _duplicates(refs):
            raise ContractError(f"{requirement_id}: duplicate capabilityIDs")
        for capability_id in refs:
            capability = capability_by_id.get(capability_id)
            if capability is None:
                raise ContractError(f"{requirement_id}: unknown capability {capability_id}")
            if capability.get("requirementID") != requirement_id:
                raise ContractError(
                    f"{capability_id}: requirementID does not match its coverage entry"
                )
            referenced_capability_ids.append(capability_id)

    duplicate_refs = _duplicates(referenced_capability_ids)
    if duplicate_refs:
        raise ContractError(f"capabilities referenced more than once: {duplicate_refs}")
    unreferenced = sorted(set(capability_ids) - set(referenced_capability_ids))
    if unreferenced:
        raise ContractError(f"capabilities missing from coverage: {unreferenced}")

    for exclusion in exclusions:
        _require_nonempty_string(
            exclusion.get("reason"), f"{exclusion.get('requirementID')}.reason"
        )
        _require_nonempty_string(
            exclusion.get("owner"), f"{exclusion.get('requirementID')}.owner"
        )

    registry = inventory.get("evidenceRegistry")
    if not isinstance(registry, dict):
        raise ContractError("evidenceRegistry must be an object")
    corpora = registry.get("corpora")
    samples = registry.get("operationSamples")
    if not isinstance(corpora, list) or not isinstance(samples, list):
        raise ContractError("evidenceRegistry arrays are missing")
    for entry in corpora:
        _validate_registry_entry(entry, "corpusID", "TYP-CORPUS-")
    for entry in samples:
        _validate_registry_entry(entry, "operationSampleID", "TYP-OP-")
    corpus_ids = [entry["corpusID"] for entry in corpora]
    sample_ids = [entry["operationSampleID"] for entry in samples]
    if _duplicates(corpus_ids):
        raise ContractError(f"duplicate corpus IDs: {_duplicates(corpus_ids)}")
    if _duplicates(sample_ids):
        raise ContractError(f"duplicate operation sample IDs: {_duplicates(sample_ids)}")
    corpus_by_id = {entry["corpusID"]: entry for entry in corpora}
    sample_by_id = {entry["operationSampleID"]: entry for entry in samples}

    benchmark = inventory.get("benchmark", {})
    benchmark_build = benchmark.get("build")
    benchmark_platform = benchmark.get("platform")
    used_corpora: set[str] = set()
    used_samples: set[str] = set()
    for capability in capabilities:
        capability_id = capability["capabilityID"]
        status = capability.get("status")
        corpus_refs = capability.get("corpusIDs")
        sample_refs = capability.get("operationSampleIDs")
        if not isinstance(corpus_refs, list) or not isinstance(sample_refs, list):
            raise ContractError(f"{capability_id}: evidence refs must be arrays")
        if _duplicates(corpus_refs) or _duplicates(sample_refs):
            raise ContractError(f"{capability_id}: duplicate evidence refs")
        if capability.get("typoraBuild") != benchmark_build:
            raise ContractError(f"{capability_id}: typoraBuild differs from benchmark")
        if capability.get("typoraPlatform") != benchmark_platform:
            raise ContractError(f"{capability_id}: platform differs from benchmark")
        evidence_url = capability.get("officialEvidenceURL")
        parsed_url = urlparse(evidence_url if isinstance(evidence_url, str) else "")
        if parsed_url.scheme != "https" or parsed_url.netloc != "support.typora.io":
            raise ContractError(f"{capability_id}: evidence URL is not official Typora support")

        for corpus_id in corpus_refs:
            evidence = corpus_by_id.get(corpus_id)
            if evidence is None:
                raise ContractError(f"{capability_id}: unknown corpus {corpus_id}")
            used_corpora.add(corpus_id)
            _validate_evidence_environment(capability, evidence, "corpus")
        for sample_id in sample_refs:
            evidence = sample_by_id.get(sample_id)
            if evidence is None:
                raise ContractError(f"{capability_id}: unknown operation sample {sample_id}")
            used_samples.add(sample_id)
            _validate_evidence_environment(capability, evidence, "operation sample")

        if status == "evidence_captured" and (corpus_refs or sample_refs):
            raise ContractError(
                f"{capability_id}: evidence_captured cannot claim corpus/sample evidence"
            )
        if status == "testing" and not (corpus_refs or sample_refs):
            raise ContractError(f"{capability_id}: testing requires registered evidence")
        if status == "aligned":
            if not (corpus_refs or sample_refs):
                raise ContractError(f"{capability_id}: aligned requires registered evidence")
            referenced_evidence = [corpus_by_id[value] for value in corpus_refs] + [
                sample_by_id[value] for value in sample_refs
            ]
            if any(entry["result"] != "passed" for entry in referenced_evidence):
                raise ContractError(
                    f"{capability_id}: aligned may reference only passed evidence"
                )

    orphan_corpora = sorted(set(corpus_ids) - used_corpora)
    orphan_samples = sorted(set(sample_ids) - used_samples)
    if orphan_corpora or orphan_samples:
        raise ContractError(
            f"orphan evidence registry entries; corpora={orphan_corpora}, "
            f"operationSamples={orphan_samples}"
        )

    exceptions = inventory.get("exceptions")
    if not isinstance(exceptions, list):
        raise ContractError("exceptions must be an array")
    exception_ids = [entry.get("exceptionID") for entry in exceptions]
    if _duplicates(exception_ids):
        raise ContractError(f"duplicate exception IDs: {_duplicates(exception_ids)}")
    exception_by_id = {entry["exceptionID"]: entry for entry in exceptions}
    used_exceptions: set[str] = set()
    for capability in capabilities:
        capability_id = capability["capabilityID"]
        exception_id = capability.get("exceptionID")
        if capability.get("status") == "exception":
            entry = exception_by_id.get(exception_id)
            if entry is None:
                raise ContractError(f"{capability_id}: missing exception ledger entry")
            if entry.get("capabilityID") != capability_id:
                raise ContractError(f"{capability_id}: exception capability mismatch")
            if entry.get("requirementID") != capability.get("requirementID"):
                raise ContractError(f"{capability_id}: exception requirement mismatch")
            used_exceptions.add(exception_id)
        elif exception_id is not None:
            raise ContractError(f"{capability_id}: non-exception has exceptionID")
    orphan_exceptions = sorted(set(exception_ids) - used_exceptions)
    if orphan_exceptions:
        raise ContractError(f"orphan exception ledger entries: {orphan_exceptions}")


def run_validator_self_test(
    inventory: dict[str, Any], schema: dict[str, Any], prd: str, benchmark: str
) -> None:
    def expect_rejected(
        label: str, negative: dict[str, Any], expected_error: str
    ) -> None:
        try:
            validate_contract(negative, schema, prd, benchmark)
        except ContractError as error:
            if expected_error not in str(error):
                raise ContractError(
                    f"validator self-test {label} failed for the wrong reason: {error}"
                ) from error
        else:
            raise ContractError(f"validator self-test accepted {label}")

    negative = deepcopy(inventory)
    negative["unexpectedAuditField"] = True
    expect_rejected("unknown top-level field", negative, "unknown=['unexpectedAuditField']")

    negative = deepcopy(inventory)
    negative["$schema"] = "https://example.invalid/weaker.schema.json"
    expect_rejected(
        "redirected schema reference",
        negative,
        "must reference the checked-in local schema",
    )

    negative = deepcopy(inventory)
    negative["capabilities"][0]["category"] = "invalid-audit-category"
    expect_rejected("invalid capability category", negative, "invalid capability category")

    negative = deepcopy(inventory)
    removed_requirement = negative["coverage"]["capabilityRefs"].pop(0)[
        "requirementID"
    ]
    expect_rejected(
        "closed-world coverage gap",
        negative,
        f"missing=['{removed_requirement}']",
    )

    negative = deepcopy(inventory)
    negative["inventoryStatus"] = "frozen"
    expect_rejected(
        "premature frozen inventory",
        negative,
        "frozen inventory has non-aligned/non-exception capabilities",
    )

    candidate_index = next(
        (
            index
            for index, capability in enumerate(inventory["capabilities"])
            if capability.get("status") == "evidence_captured"
            and not capability.get("corpusIDs")
            and not capability.get("operationSampleIDs")
        ),
        None,
    )
    if candidate_index is None:
        raise ContractError(
            "validator self-test needs an evidence_captured capability without evidence refs"
        )

    benchmark_platform = inventory["benchmark"]["platform"]
    wrong_architecture = (
        "x86_64" if benchmark_platform["architecture"] == "arm64" else "arm64"
    )
    negative_cases = (
        ("os", "audit-os", "corpus os mismatch"),
        ("architecture", wrong_architecture, "corpus architecture mismatch"),
    )
    for field, invalid_value, expected_error in negative_cases:
        negative = deepcopy(inventory)
        capability = negative["capabilities"][candidate_index]
        evidence_id = f"TYP-CORPUS-PLATFORM-{field.upper()}-NEGATIVE"
        capability["status"] = "aligned"
        capability["corpusIDs"] = [evidence_id]
        environment = {
            "os": benchmark_platform["os"],
            "architecture": benchmark_platform["architecture"],
            "typoraBuild": capability["typoraBuild"],
            "settingsProfile": capability["settingsProfile"],
            "locale": "en-US",
        }
        environment[field] = invalid_value
        negative["evidenceRegistry"]["corpora"].append(
            {
                "corpusID": evidence_id,
                "sha256": "1" * 64,
                "artifactURI": f"urn:inflow:self-test:{field}",
                "environment": environment,
                "result": "passed",
                "capturedDate": negative["benchmark"]["capturedDate"],
                "owner": "Inventory Validator Self-Test",
            }
        )
        expect_rejected(f"mismatched evidence {field}", negative, expected_error)


def _cell(value: Any) -> str:
    return str(value).replace("|", "\\|").replace("\n", " ")


def render_markdown(inventory: dict[str, Any]) -> str:
    benchmark = inventory["benchmark"]
    coverage = inventory["coverage"]
    capabilities = inventory["capabilities"]
    capability_by_id = {
        capability["capabilityID"]: capability for capability in capabilities
    }
    registry = inventory["evidenceRegistry"]
    exceptions = inventory["exceptions"]

    lines = [
        "# Typora Capability Inventory\uff08\u673a\u5668\u751f\u6210\u9605\u8bfb\u89c6\u56fe\uff09",
        "",
        "> \u8bf7\u52ff\u624b\u5de5\u7f16\u8f91\u672c\u6587\u4ef6\u3002\u6743\u5a01\u6570\u636e\u6765\u81ea "
        "[`TYPORA_CAPABILITY_INVENTORY.json`](./TYPORA_CAPABILITY_INVENTORY.json)\uff1b\u8fd0\u884c "
        "`python3 scripts/generate_typora_inventory_view.py` \u91cd\u65b0\u751f\u6210\u3002",
        "",
        "## \u57fa\u7ebf",
        "",
        "| \u5b57\u6bb5 | \u503c |",
        "| --- | --- |",
        f"| Inventory \u7248\u672c | `{_cell(inventory['inventoryVersion'])}` |",
        f"| \u6570\u636e\u72b6\u6001 | `{_cell(inventory['inventoryStatus'])}` |",
        f"| \u57fa\u51c6\u4ea7\u54c1 | {_cell(benchmark['product'])} `{_cell(benchmark['build'])}` / `{_cell(benchmark['channel'])}` |",
        f"| \u5e73\u53f0 | {_cell(benchmark['platform']['os'])} / `{_cell(benchmark['platform']['architecture'])}` |",
        f"| \u8bc1\u636e\u6355\u83b7\u65e5 | `{_cell(benchmark['capturedDate'])}` |",
        f"| \u751f\u6210\u65f6\u95f4 | `{_cell(inventory['generatedAt'])}` |",
        "",
        "`evidence_captured` \u53ea\u8868\u793a build/\u5e73\u53f0\u6807\u7b7e\u3001settings profile \u6807\u8bc6\u3001\u5b98\u65b9 URL/\u65e5\u671f\u548c owner \u5df2\u767b\u8bb0\uff1b\u4e0d\u8868\u793a\u53ef\u590d\u73b0\u8bbe\u7f6e\u5de5\u4ef6\u5df2\u51bb\u7ed3\u3001\u884c\u4e3a\u5df2\u9a8c\u8bc1\u3001corpus \u5df2\u901a\u8fc7\u6216\u80fd\u529b\u5df2 `aligned`\u3002",
        "",
        "## PRD \u5c01\u95ed\u4e16\u754c\u8986\u76d6",
        "",
        f"\u5df2\u6620\u5c04 `{len(coverage['capabilityRefs'])}` \u6761 requirement\uff0c\u663e\u5f0f\u6392\u9664 `{len(coverage['exclusions'])}` \u6761\uff1b\u4e24\u8005\u5fc5\u987b\u6070\u597d\u8986\u76d6 PRD \u7b2c 11 \u8282\u6240\u6709\u975e DoD `INF-P0`\u2013`INF-P3` feature ID\u3002",
        "",
        "### \u80fd\u529b\u6620\u5c04",
        "",
        "| Requirement ID | Capability refs | \u72b6\u6001 |",
        "| --- | --- | --- |",
    ]
    for entry in coverage["capabilityRefs"]:
        refs = entry["capabilityIDs"]
        refs_markdown = "<br>".join(f"`{_cell(value)}`" for value in refs)
        statuses = sorted({capability_by_id[value]["status"] for value in refs})
        status_markdown = ", ".join(f"`{_cell(value)}`" for value in statuses)
        lines.append(
            f"| `{_cell(entry['requirementID'])}` | {refs_markdown} | {status_markdown} |"
        )

    lines.extend(
        [
            "",
            "### \u8986\u76d6\u6392\u9664",
            "",
            "| Requirement ID | \u6392\u9664\u7406\u7531 | Owner |",
            "| --- | --- | --- |",
        ]
    )
    for entry in coverage["exclusions"]:
        lines.append(
            f"| `{_cell(entry['requirementID'])}` | {_cell(entry['reason'])} | {_cell(entry['owner'])} |"
        )

    lines.extend(
        [
            "",
            "## \u80fd\u529b\u8bc1\u636e\u8bb0\u5f55",
            "",
            "| Capability ID | Requirement ID | \u72b6\u6001 | \u5b98\u65b9\u8bc1\u636e | Owner |",
            "| --- | --- | --- | --- | --- |",
        ]
    )
    for capability in sorted(
        capabilities, key=lambda value: (value["requirementID"], value["capabilityID"])
    ):
        lines.append(
            f"| `{_cell(capability['capabilityID'])}` | "
            f"`{_cell(capability['requirementID'])}` | "
            f"`{_cell(capability['status'])}` | "
            f"[Typora Support]({_cell(capability['officialEvidenceURL'])}) | "
            f"{_cell(capability['owner'])} |"
        )

    lines.extend(
        [
            "",
            "## Corpus / \u64cd\u4f5c\u6837\u672c\u767b\u8bb0",
            "",
            f"- Corpus\uff1a`{len(registry['corpora'])}` \u6761",
            f"- Operation sample\uff1a`{len(registry['operationSamples'])}` \u6761",
            "",
        ]
    )
    if not registry["corpora"] and not registry["operationSamples"]:
        lines.extend(
            [
                "\u5f53\u524d\u6ca1\u6709\u51bb\u7ed3 corpus \u6216\u64cd\u4f5c\u6837\u672c\uff0c\u56e0\u6b64 Inventory \u4e0d\u5ba3\u79f0\u4efb\u4f55\u80fd\u529b\u5df2 `aligned`\u3002\u65b0\u589e\u8bc1\u636e\u65f6\u5fc5\u987b\u767b\u8bb0\u975e\u5168\u96f6 SHA-256\u3001\u5b8c\u6574\u73af\u5883\u4e0e `passed | failed | pending` \u7ed3\u679c\u3002",
                "",
            ]
        )
    else:
        lines.extend(
            [
                "| Evidence ID | \u7c7b\u578b | SHA-256 | \u7ed3\u679c | Build / \u8bbe\u7f6e |",
                "| --- | --- | --- | --- | --- |",
            ]
        )
        for entry in registry["corpora"]:
            environment = entry["environment"]
            lines.append(
                f"| `{_cell(entry['corpusID'])}` | corpus | `{_cell(entry['sha256'])}` | "
                f"`{_cell(entry['result'])}` | `{_cell(environment['typoraBuild'])}` / "
                f"`{_cell(environment['settingsProfile'])}` |"
            )
        for entry in registry["operationSamples"]:
            environment = entry["environment"]
            lines.append(
                f"| `{_cell(entry['operationSampleID'])}` | operation | `{_cell(entry['sha256'])}` | "
                f"`{_cell(entry['result'])}` | `{_cell(environment['typoraBuild'])}` / "
                f"`{_cell(environment['settingsProfile'])}` |"
            )
        lines.append("")

    lines.extend(
        [
            "## \u516c\u5f00 Exception Ledger",
            "",
            "| Exception ID | Capability ID | Requirement ID | \u72b6\u6001 | \u7406\u7531 |",
            "| --- | --- | --- | --- | --- |",
        ]
    )
    for entry in exceptions:
        lines.append(
            f"| `{_cell(entry['exceptionID'])}` | `{_cell(entry['capabilityID'])}` | "
            f"`{_cell(entry['requirementID'])}` | `{_cell(entry['status'])}` | "
            f"{_cell(entry['reason'])} |"
        )

    lines.extend(
        [
            "",
            "## \u673a\u5668\u95e8\u7981",
            "",
            "\u751f\u6210\u5668\u4f1a\u5f3a\u5236\u6821\u9a8c\uff1a",
            "",
            "- PRD \u975e DoD feature ID \u5fc5\u987b\u6070\u597d\u51fa\u73b0\u5728\u4e00\u6761 capability mapping \u6216\u4e00\u6761\u5e26 reason/owner \u7684 coverage exclusion \u4e2d\u3002",
            "- Benchmark \u673a\u5668\u8986\u76d6\u533a\u4e0e capability ID \u5fc5\u987b\u53cc\u5411\u95ed\u96c6\uff0c\u9ad8\u4eae/\u4e0a\u6807/\u4e0b\u6807/Emoji \u7b49\u660e\u5217\u80fd\u529b\u4e0d\u5f97\u88ab\u5bbd\u6cdb parity \u9879\u9690\u85cf\u3002",
            "- capability\u3001requirement\u3001exception \u548c evidence ID \u5fc5\u987b\u552f\u4e00\u4e14\u53cc\u5411\u5f15\u7528\u4e00\u81f4\u3002",
            "- `evidence_captured` \u4e0d\u5f97\u5f15\u7528 corpus/sample\uff1b`testing` \u5fc5\u987b\u5f15\u7528\u5df2\u767b\u8bb0\u8bc1\u636e\u3002",
            "- `aligned` \u5fc5\u987b\u5f15\u7528 Registry \u4e2d\u73af\u5883\u4e00\u81f4\u4e14\u7ed3\u679c\u5168\u4e3a `passed` \u7684 corpus/sample\u3002",
            "- Registry \u62d2\u7edd\u5168\u96f6 SHA-256\u3001\u4e0d\u5b8c\u6574\u73af\u5883\u3001\u65e0\u6548\u7ed3\u679c\u548c\u65e0\u4eba\u5f15\u7528\u7684\u5b64\u513f\u8bc1\u636e\u3002",
            "",
            "\u4ece\u4ed3\u5e93\u6839\u76ee\u5f55\u6267\u884c\u751f\u6210\u89c6\u56fe\u3001\u5185\u5b58\u8d1f\u4f8b\u548c全局 JSON Schema/\u5f15\u7528\u6821\u9a8c\uff1a",
            "",
            "```sh",
            "python3 scripts/generate_typora_inventory_view.py --check",
            "python3 scripts/generate_typora_inventory_view.py --self-test",
            "python3 scripts/validate_docs.py",
            "```",
            "",
            "P1\u2013P3 \u8303\u56f4\u548c DoD \u4ecd\u53ea\u7531 [PRD](./PRD.md) \u5b9a\u4e49\uff1bInventory \u4e0d\u6269\u5927\u4ea7\u54c1\u8303\u56f4\u3002",
            "",
        ]
    )
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--check",
        action="store_true",
        help="fail when the checked-in Markdown view is stale",
    )
    mode.add_argument(
        "--self-test",
        action="store_true",
        help="run in-memory negative tests for validator invariants",
    )
    args = parser.parse_args()

    try:
        inventory = load_json(INVENTORY_PATH)
        schema = load_json(SCHEMA_PATH)
        prd = PRD_PATH.read_text(encoding="utf-8")
        benchmark = BENCHMARK_PATH.read_text(encoding="utf-8")
        validate_contract(inventory, schema, prd, benchmark)
        rendered = render_markdown(inventory)
    except (OSError, ContractError) as error:
        print(f"Typora Inventory validation failed: {error}", file=sys.stderr)
        return 1

    if args.self_test:
        try:
            run_validator_self_test(inventory, schema, prd, benchmark)
        except ContractError as error:
            print(f"Typora Inventory validator self-test failed: {error}", file=sys.stderr)
            return 1
        print(
            "Typora Inventory validator self-test rejected shape/schema-ref, category, "
            "coverage, premature-frozen, and OS/architecture negatives"
        )
        return 0

    if args.check:
        try:
            current = VIEW_PATH.read_text(encoding="utf-8")
        except OSError as error:
            print(f"cannot read {VIEW_PATH.relative_to(ROOT)}: {error}", file=sys.stderr)
            return 1
        if current != rendered:
            print(
                "Typora Inventory Markdown view is stale; run "
                "python3 scripts/generate_typora_inventory_view.py",
                file=sys.stderr,
            )
            return 1
        print("Typora Inventory contract and Markdown view are current")
        return 0

    VIEW_PATH.write_text(rendered, encoding="utf-8")
    print(f"generated {VIEW_PATH.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Validate Inflow's documentation contracts without third-party packages."""

from __future__ import annotations

import json
import re
import subprocess
import sys
import uuid
from datetime import date, datetime
from pathlib import Path
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "文档"
LOCAL_LINK = re.compile(r"\]\((?:<)?(?P<target>\.\.?/[^)>#]+)(?:#[^)>]*)?(?:>)?\)")
REQUIREMENT_ID = re.compile(r"\bINF-P[0-3]-[A-Z][A-Z0-9]*-\d{3}\b")
SHA256 = re.compile(r"^(?!0{64}$)[0-9a-f]{64}$")
REQUIREMENT_DEFINITION = re.compile(r"\*\*(INF-P[0-3]-[A-Z][A-Z0-9]*-\d{3})\*\*")
EXPECTED_LOCAL_SCHEMA_REFS = {
    "治理/需求追踪.json": "./需求追踪模式.json",
    "技术/扩展/AI运行清单.json": "./数据模式/AI运行清单第二版模式.json",
    "技术/扩展/扩展钥匙串映射.json": "./数据模式/扩展钥匙串映射第一版模式.json",
    "技术/扩展/IPC信任矩阵.json": "./数据模式/IPC信任矩阵第一版模式.json",
    "技术/扩展/市场代理策略.json": "./数据模式/市场代理策略第一版模式.json",
    "技术/扩展/阶段进程矩阵.json": "./数据模式/阶段进程矩阵第二版模式.json",
    "技术/扩展/类型化适配器策略.json": "./数据模式/类型化适配器策略第一版模式.json",
    "产品/Typora能力清单.json": "./Typora能力清单模式.json",
}


class DuplicateKey(ValueError):
    pass


def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateKey(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_json(path: Path) -> object:
    return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_object)


def check_json(errors: list[str]) -> dict[Path, object]:
    loaded: dict[Path, object] = {}
    for path in sorted(DOCS.rglob("*.json")):
        try:
            document = load_json(path)
            loaded[path] = document
        except (OSError, UnicodeError, json.JSONDecodeError, DuplicateKey) as exc:
            errors.append(f"{path.relative_to(ROOT)}: {exc}")
            continue

        if isinstance(document, dict):
            schema_ref = document.get("$schema")
            if (
                isinstance(schema_ref, str)
                and schema_ref.startswith(("http://", "https://"))
                and not path.name.endswith("模式.json")
            ):
                errors.append(
                    f"{path.relative_to(ROOT)}: contract instances must use a checked local $schema"
                )
            elif isinstance(schema_ref, str) and not schema_ref.startswith(
                ("http://", "https://")
            ):
                schema_path = (path.parent / unquote(schema_ref.split("#", 1)[0])).resolve()
                if not schema_path.is_file():
                    errors.append(
                        f"{path.relative_to(ROOT)}: missing local $schema {schema_ref}"
                    )
    return loaded


def resolve_json_pointer(root: object, reference: str) -> object:
    if not reference.startswith("#"):
        raise ValueError(f"only local JSON Schema references are supported: {reference}")
    current = root
    pointer = reference[1:]
    if not pointer:
        return current
    if not pointer.startswith("/"):
        raise ValueError(f"invalid JSON pointer: {reference}")
    for raw_part in pointer[1:].split("/"):
        part = raw_part.replace("~1", "/").replace("~0", "~")
        if isinstance(current, dict) and part in current:
            current = current[part]
        elif isinstance(current, list) and part.isdigit() and int(part) < len(current):
            current = current[int(part)]
        else:
            raise ValueError(f"unresolvable JSON pointer: {reference}")
    return current


def matches_json_type(instance: object, expected: str) -> bool:
    return {
        "null": instance is None,
        "boolean": isinstance(instance, bool),
        "integer": isinstance(instance, int) and not isinstance(instance, bool),
        "number": isinstance(instance, (int, float)) and not isinstance(instance, bool),
        "string": isinstance(instance, str),
        "array": isinstance(instance, list),
        "object": isinstance(instance, dict),
    }.get(expected, False)


def check_schema_format(value: str, format_name: str) -> bool:
    try:
        if format_name == "date":
            date.fromisoformat(value)
        elif format_name == "date-time":
            datetime.fromisoformat(value.replace("Z", "+00:00"))
        elif format_name == "uuid":
            uuid.UUID(value)
        elif format_name in {"uri", "uri-reference"}:
            parsed = urlsplit(value)
            if format_name == "uri" and not parsed.scheme:
                return False
        else:
            return True
    except (ValueError, TypeError):
        return False
    return True


def evaluated_object_properties(
    instance: dict[str, object],
    schema: object,
    root_schema: object,
    seen: set[int] | None = None,
) -> set[str]:
    """Collect object-property annotations needed by unevaluatedProperties.

    This implements the Draft 2020-12 composition used by the checked-in
    contracts: local properties/patternProperties, local references, allOf,
    successful anyOf/oneOf branches, and the selected conditional branch.
    """

    if not isinstance(schema, dict):
        return set()
    if seen is None:
        seen = set()
    identity = id(schema)
    if identity in seen:
        return set()
    branch_seen = set(seen)
    branch_seen.add(identity)

    evaluated: set[str] = set()
    properties = schema.get("properties")
    if isinstance(properties, dict):
        evaluated.update(key for key in instance if key in properties)
    pattern_properties = schema.get("patternProperties")
    if isinstance(pattern_properties, dict):
        for key in instance:
            for pattern in pattern_properties:
                try:
                    if re.search(pattern, key) is not None:
                        evaluated.add(key)
                except re.error:
                    continue

    reference = schema.get("$ref")
    if isinstance(reference, str):
        try:
            target = resolve_json_pointer(root_schema, reference)
        except ValueError:
            pass
        else:
            evaluated.update(
                evaluated_object_properties(
                    instance, target, root_schema, branch_seen
                )
            )

    all_of = schema.get("allOf")
    if isinstance(all_of, list):
        for child_schema in all_of:
            evaluated.update(
                evaluated_object_properties(
                    instance, child_schema, root_schema, branch_seen
                )
            )

    for keyword in ("anyOf", "oneOf"):
        alternatives = schema.get(keyword)
        if not isinstance(alternatives, list):
            continue
        for child_schema in alternatives:
            if not validate_schema_node(
                instance, child_schema, root_schema, "annotation"
            ):
                evaluated.update(
                    evaluated_object_properties(
                        instance, child_schema, root_schema, branch_seen
                    )
                )

    condition = schema.get("if")
    if condition is not None:
        branch = "then" if not validate_schema_node(
            instance, condition, root_schema, "annotation"
        ) else "else"
        if branch in schema:
            evaluated.update(
                evaluated_object_properties(
                    instance, schema[branch], root_schema, branch_seen
                )
            )

    return evaluated


def validate_schema_node(
    instance: object,
    schema: object,
    root_schema: object,
    location: str,
) -> list[str]:
    if schema is True:
        return []
    if schema is False:
        return [f"{location}: rejected by false schema"]
    if not isinstance(schema, dict):
        return [f"{location}: invalid schema node"]

    failures: list[str] = []
    reference = schema.get("$ref")
    if isinstance(reference, str):
        try:
            target = resolve_json_pointer(root_schema, reference)
        except ValueError as exc:
            failures.append(f"{location}: {exc}")
        else:
            failures.extend(validate_schema_node(instance, target, root_schema, location))

    if "const" in schema and instance != schema["const"]:
        failures.append(f"{location}: value does not match const")
    enum = schema.get("enum")
    if isinstance(enum, list) and instance not in enum:
        failures.append(f"{location}: value is not in enum")

    expected_type = schema.get("type")
    if isinstance(expected_type, str):
        valid_type = matches_json_type(instance, expected_type)
    elif isinstance(expected_type, list):
        valid_type = any(
            isinstance(item, str) and matches_json_type(instance, item)
            for item in expected_type
        )
    else:
        valid_type = True
    if not valid_type:
        failures.append(f"{location}: expected JSON type {expected_type!r}")
        return failures

    for subschema in schema.get("allOf", []):
        failures.extend(validate_schema_node(instance, subschema, root_schema, location))

    for keyword, required_matches in (("anyOf", 1), ("oneOf", 1)):
        alternatives = schema.get(keyword)
        if isinstance(alternatives, list):
            matches = sum(
                not validate_schema_node(instance, candidate, root_schema, location)
                for candidate in alternatives
            )
            if (keyword == "anyOf" and matches < required_matches) or (
                keyword == "oneOf" and matches != required_matches
            ):
                failures.append(
                    f"{location}: {keyword} matched {matches} alternatives, expected "
                    f"{'at least one' if keyword == 'anyOf' else 'exactly one'}"
                )

    negated = schema.get("not")
    if negated is not None and not validate_schema_node(
        instance, negated, root_schema, location
    ):
        failures.append(f"{location}: value matches forbidden schema")

    condition = schema.get("if")
    if condition is not None:
        branch = "then" if not validate_schema_node(
            instance, condition, root_schema, location
        ) else "else"
        if branch in schema:
            failures.extend(
                validate_schema_node(instance, schema[branch], root_schema, location)
            )

    if isinstance(instance, dict):
        required = schema.get("required", [])
        if isinstance(required, list):
            for key in required:
                if isinstance(key, str) and key not in instance:
                    failures.append(f"{location}: missing required property {key}")
        properties = schema.get("properties", {})
        if not isinstance(properties, dict):
            properties = {}
        pattern_properties = schema.get("patternProperties", {})
        if not isinstance(pattern_properties, dict):
            pattern_properties = {}
        evaluated: set[str] = set()
        for key, value in instance.items():
            child = f"{location}.{key}"
            if key in properties:
                evaluated.add(key)
                failures.extend(
                    validate_schema_node(value, properties[key], root_schema, child)
                )
            for pattern, child_schema in pattern_properties.items():
                try:
                    matched = re.search(pattern, key) is not None
                except re.error:
                    failures.append(f"{location}: invalid patternProperties regex {pattern!r}")
                    matched = False
                if matched:
                    evaluated.add(key)
                    failures.extend(
                        validate_schema_node(value, child_schema, root_schema, child)
                    )
        additional = schema.get("additionalProperties", True)
        for key in set(instance) - evaluated:
            if additional is False:
                failures.append(f"{location}: unknown property {key}")
            elif isinstance(additional, dict):
                failures.extend(
                    validate_schema_node(
                        instance[key], additional, root_schema, f"{location}.{key}"
                    )
                )
        minimum_properties = schema.get("minProperties")
        maximum_properties = schema.get("maxProperties")
        if isinstance(minimum_properties, int) and len(instance) < minimum_properties:
            failures.append(f"{location}: fewer than minProperties")
        if isinstance(maximum_properties, int) and len(instance) > maximum_properties:
            failures.append(f"{location}: more than maxProperties")
        dependent = schema.get("dependentRequired", {})
        if isinstance(dependent, dict):
            for key, dependencies in dependent.items():
                if key in instance and isinstance(dependencies, list):
                    for dependency in dependencies:
                        if dependency not in instance:
                            failures.append(
                                f"{location}: {key} requires property {dependency}"
                            )
        unevaluated = schema.get("unevaluatedProperties")
        if unevaluated is not None:
            annotated = evaluated_object_properties(instance, schema, root_schema)
            for key in set(instance) - annotated:
                if unevaluated is False:
                    failures.append(f"{location}: unevaluated property {key}")
                elif isinstance(unevaluated, dict):
                    failures.extend(
                        validate_schema_node(
                            instance[key],
                            unevaluated,
                            root_schema,
                            f"{location}.{key}",
                        )
                    )

    if isinstance(instance, list):
        minimum_items = schema.get("minItems")
        maximum_items = schema.get("maxItems")
        if isinstance(minimum_items, int) and len(instance) < minimum_items:
            failures.append(f"{location}: fewer than minItems")
        if isinstance(maximum_items, int) and len(instance) > maximum_items:
            failures.append(f"{location}: more than maxItems")
        if schema.get("uniqueItems") is True:
            encoded = [
                json.dumps(item, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
                for item in instance
            ]
            if len(encoded) != len(set(encoded)):
                failures.append(f"{location}: array items are not unique")
        items_schema = schema.get("items")
        if isinstance(items_schema, (dict, bool)):
            for index, value in enumerate(instance):
                failures.extend(
                    validate_schema_node(
                        value, items_schema, root_schema, f"{location}[{index}]"
                    )
                )
        contains = schema.get("contains")
        if isinstance(contains, (dict, bool)):
            matches = sum(
                not validate_schema_node(value, contains, root_schema, location)
                for value in instance
            )
            minimum_contains = schema.get("minContains", 1)
            maximum_contains = schema.get("maxContains")
            if matches < minimum_contains:
                failures.append(f"{location}: contains matched too few items")
            if isinstance(maximum_contains, int) and matches > maximum_contains:
                failures.append(f"{location}: contains matched too many items")

    if isinstance(instance, str):
        minimum_length = schema.get("minLength")
        maximum_length = schema.get("maxLength")
        if isinstance(minimum_length, int) and len(instance) < minimum_length:
            failures.append(f"{location}: shorter than minLength")
        if isinstance(maximum_length, int) and len(instance) > maximum_length:
            failures.append(f"{location}: longer than maxLength")
        pattern = schema.get("pattern")
        if isinstance(pattern, str):
            try:
                if re.search(pattern, instance) is None:
                    failures.append(f"{location}: does not match pattern")
            except re.error as exc:
                failures.append(f"{location}: invalid schema regex: {exc}")
        format_name = schema.get("format")
        if isinstance(format_name, str) and not check_schema_format(instance, format_name):
            failures.append(f"{location}: invalid {format_name} format")

    if isinstance(instance, (int, float)) and not isinstance(instance, bool):
        minimum = schema.get("minimum")
        maximum = schema.get("maximum")
        exclusive_minimum = schema.get("exclusiveMinimum")
        exclusive_maximum = schema.get("exclusiveMaximum")
        if isinstance(minimum, (int, float)) and instance < minimum:
            failures.append(f"{location}: below minimum")
        if isinstance(maximum, (int, float)) and instance > maximum:
            failures.append(f"{location}: above maximum")
        if (
            isinstance(exclusive_minimum, (int, float))
            and instance <= exclusive_minimum
        ):
            failures.append(f"{location}: not above exclusiveMinimum")
        if (
            isinstance(exclusive_maximum, (int, float))
            and instance >= exclusive_maximum
        ):
            failures.append(f"{location}: not below exclusiveMaximum")

    return failures


def check_schema_instances(loaded: dict[Path, object], errors: list[str]) -> None:
    pairs: list[tuple[Path, Path]] = []
    for path, document in loaded.items():
        if not isinstance(document, dict):
            continue
        schema_ref = document.get("$schema")
        if isinstance(schema_ref, str) and not schema_ref.startswith(("http://", "https://")):
            pairs.append((path, (path.parent / unquote(schema_ref)).resolve()))

    for relative_instance, expected_ref in EXPECTED_LOCAL_SCHEMA_REFS.items():
        instance_path = DOCS / relative_instance
        document = loaded.get(instance_path)
        if not isinstance(document, dict):
            errors.append(f"文档/{relative_instance}: missing required schema-bound instance")
            continue
        if document.get("$schema") != expected_ref:
            errors.append(
                f"文档/{relative_instance}: $schema must be exactly {expected_ref}"
            )
        pairs.append(
            (instance_path, (instance_path.parent / unquote(expected_ref)).resolve())
        )

    seen: set[tuple[Path, Path]] = set()
    for instance_path, schema_path in pairs:
        pair = (instance_path, schema_path)
        if pair in seen:
            continue
        seen.add(pair)
        instance = loaded.get(instance_path)
        schema = loaded.get(schema_path)
        if schema is None:
            errors.append(
                f"{instance_path.relative_to(ROOT)}: schema was not parsed: "
                f"{schema_path.relative_to(ROOT)}"
            )
            continue
        failures = validate_schema_node(
            instance, schema, schema, str(instance_path.relative_to(ROOT))
        )
        errors.extend(failures)


def check_markdown_links(errors: list[str]) -> None:
    for path in sorted(DOCS.rglob("*.md")):
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as exc:
            errors.append(f"{path.relative_to(ROOT)}: {exc}")
            continue
        in_fence = False
        for line_number, line_text in enumerate(text.splitlines(), start=1):
            if line_text.lstrip().startswith("```"):
                in_fence = not in_fence
                continue
            if in_fence:
                continue
            prose = re.sub(r"`[^`]*`", "", line_text)
            for match in LOCAL_LINK.finditer(prose):
                target = unquote(match.group("target"))
                resolved = (path.parent / target).resolve()
                if not resolved.exists():
                    errors.append(
                        f"{path.relative_to(ROOT)}:{line_number}: missing local link target {target}"
                    )
        if in_fence:
            errors.append(f"{path.relative_to(ROOT)}: unclosed Markdown code fence")


def check_prd_requirement_definitions(errors: list[str]) -> None:
    path = DOCS / "产品" / "产品需求文档.md"
    definitions = REQUIREMENT_DEFINITION.findall(path.read_text(encoding="utf-8"))
    seen: set[str] = set()
    for requirement_id in definitions:
        if requirement_id in seen:
            errors.append(
                f"{path.relative_to(ROOT)}: duplicate requirement definition {requirement_id}"
            )
        seen.add(requirement_id)
    if not definitions:
        errors.append(f"{path.relative_to(ROOT)}: no stable requirement definitions found")


def document_at(loaded: dict[Path, object], relative: str) -> dict[str, object] | None:
    document = loaded.get(DOCS / relative)
    return document if isinstance(document, dict) else None


def check_declared_authority_paths(
    loaded: dict[Path, object], errors: list[str]
) -> None:
    """Validate semantic file references that are not Markdown links or $schema refs."""

    declarations = (
        (
            "治理/需求追踪.json",
            ("sourceRequirementLedger",),
            "产品/产品需求文档.md",
        ),
        (
            "技术/扩展/扩展钥匙串映射.json",
            ("normativeSource",),
            "技术/核心/钥匙串策略.json",
        ),
        (
            "技术/核心/性能清单.json",
            ("processSampling", "machineTargetAuthority"),
            "技术/扩展/阶段进程矩阵.json",
        ),
    )
    for source_relative, field_path, target_relative in declarations:
        source = DOCS / source_relative
        document = loaded.get(source)
        if not isinstance(document, dict):
            errors.append(f"{source.relative_to(ROOT)}: missing path authority source")
            continue
        value: object = document
        for field in field_path:
            value = value.get(field) if isinstance(value, dict) else None
        field_name = ".".join(field_path)
        if not isinstance(value, str) or not value.startswith(("./", "../")):
            errors.append(
                f"{source.relative_to(ROOT)}: {field_name} must be a relative local path"
            )
            continue
        resolved = (source.parent / unquote(value)).resolve()
        expected = (DOCS / target_relative).resolve()
        if resolved != expected or not resolved.is_file():
            errors.append(
                f"{source.relative_to(ROOT)}: {field_name} does not resolve to "
                f"文档/{target_relative}"
            )


def check_machine_authority_cross_references(
    loaded: dict[Path, object], errors: list[str]
) -> None:
    keychain = document_at(loaded, "技术/核心/钥匙串策略.json")
    projection = document_at(
        loaded, "技术/扩展/扩展钥匙串映射.json"
    )
    phase_matrix = document_at(
        loaded, "技术/扩展/阶段进程矩阵.json"
    )
    ipc_matrix = document_at(loaded, "技术/扩展/IPC信任矩阵.json")
    typed_adapters = document_at(
        loaded, "技术/扩展/类型化适配器策略.json"
    )
    market_policy = document_at(
        loaded, "技术/扩展/市场代理策略.json"
    )
    if not all(
        (keychain, projection, phase_matrix, ipc_matrix, typed_adapters, market_policy)
    ):
        errors.append("machine authority cross-check: one or more normative JSON files are missing")
        return

    global_groups = keychain.get("accessGroups")
    projected_groups = projection.get("accessGroups")
    if not isinstance(global_groups, dict) or not isinstance(projected_groups, list):
        errors.append("Keychain authority/projection accessGroups have invalid shapes")
        return

    projection_by_id: dict[str, dict[str, object]] = {}
    for index, entry in enumerate(projected_groups):
        if not isinstance(entry, dict) or not isinstance(entry.get("id"), str):
            errors.append(f"EXTENSION_KEYCHAIN_PROJECTION accessGroups[{index}] is invalid")
            continue
        group_id = entry["id"]
        if group_id in projection_by_id:
            errors.append(f"EXTENSION_KEYCHAIN_PROJECTION duplicates access group {group_id}")
        projection_by_id[group_id] = entry

    if set(projection_by_id) != set(global_groups):
        errors.append(
            "EXTENSION_KEYCHAIN_PROJECTION access-group IDs must exactly match KEYCHAIN_POLICY"
        )
    for group_id, global_entry in global_groups.items():
        projected = projection_by_id.get(group_id)
        if not isinstance(global_entry, dict) or projected is None:
            continue
        comparisons = {
            "logicalAccessGroup": global_entry.get("logicalSuffix"),
            "targets": global_entry.get("allowedSignedTargets"),
            "secretClasses": global_entry.get("secretClasses"),
        }
        for projected_key, expected in comparisons.items():
            if projected.get(projected_key) != expected:
                errors.append(
                    f"EXTENSION_KEYCHAIN_PROJECTION {group_id}.{projected_key} "
                    f"does not match KEYCHAIN_POLICY"
                )

    targets = phase_matrix.get("targets")
    phases = phase_matrix.get("phases")
    listeners = ipc_matrix.get("listeners")
    if (
        not isinstance(targets, list)
        or not isinstance(phases, list)
        or not isinstance(listeners, list)
    ):
        errors.append("Phase/IPC authority phases, targets, or listeners have invalid shapes")
        return
    phase_ids = [
        entry.get("id")
        for entry in phases
        if isinstance(entry, dict) and isinstance(entry.get("id"), str)
    ]
    if len(phase_ids) != len(phases) or len(set(phase_ids)) != len(phase_ids):
        errors.append("PHASE_PROCESS_MATRIX has missing or duplicate phase IDs")
    if set(phase_ids) != {f"E{number}" for number in range(6)}:
        errors.append("PHASE_PROCESS_MATRIX phases must be exactly E0 through E5")
    target_ids = {
        entry.get("id") for entry in targets if isinstance(entry, dict) and isinstance(entry.get("id"), str)
    }
    if len(target_ids) != len(targets):
        errors.append("PHASE_PROCESS_MATRIX has missing or duplicate target IDs")
    signed_targets = keychain.get("signedTargets")
    if not isinstance(signed_targets, dict) or set(signed_targets) != target_ids:
        errors.append(
            "KEYCHAIN_POLICY signedTargets must exactly match PHASE_PROCESS_MATRIX targets"
        )
    expected_groups_by_target: dict[str, set[str]] = {
        target_id: set() for target_id in target_ids
    }
    for group_id, global_entry in global_groups.items():
        if not isinstance(global_entry, dict):
            continue
        for target_id in global_entry.get("allowedSignedTargets", []):
            if target_id not in target_ids:
                errors.append(
                    f"KEYCHAIN_POLICY access group {group_id} references unknown target {target_id}"
                )
            expected_groups_by_target.setdefault(target_id, set()).add(group_id)
    for entry in targets:
        if not isinstance(entry, dict):
            continue
        target_id = entry.get("id")
        phase_group_refs = entry.get("keychainPolicyRefs", [])
        for group_id in phase_group_refs:
            if group_id not in global_groups:
                errors.append(
                    f"PHASE_PROCESS_MATRIX target {target_id} references unknown Keychain group {group_id}"
                )
        if isinstance(target_id, str) and set(phase_group_refs) != expected_groups_by_target.get(
            target_id, set()
        ):
            errors.append(
                f"PHASE_PROCESS_MATRIX target {target_id} Keychain refs do not exactly "
                "match KEYCHAIN_POLICY"
            )
    listener_ids: set[str] = set()
    for index, listener in enumerate(listeners):
        if not isinstance(listener, dict):
            errors.append(f"IPC_TRUST_MATRIX listeners[{index}] is invalid")
            continue
        listener_id = listener.get("id")
        if not isinstance(listener_id, str) or not listener_id:
            errors.append(f"IPC_TRUST_MATRIX listeners[{index}] lacks an ID")
        elif listener_id in listener_ids:
            errors.append(f"IPC_TRUST_MATRIX duplicates listener ID {listener_id}")
        else:
            listener_ids.add(listener_id)
        listener_target = listener.get("target")
        if listener_target not in target_ids:
            errors.append(
                f"IPC_TRUST_MATRIX listener {listener.get('id')} references unknown target {listener_target}"
            )
        for peer in listener.get("authorizedPeers", []):
            if peer not in target_ids:
                errors.append(
                    f"IPC_TRUST_MATRIX listener {listener.get('id')} references unknown peer {peer}"
                )

    policies = typed_adapters.get("policies")
    if not isinstance(policies, list):
        errors.append("TYPED_ADAPTER_POLICIES policies must be an array")
    else:
        policy_ids: set[str] = set()
        adapter_ids: set[str] = set()
        for index, policy in enumerate(policies):
            if not isinstance(policy, dict):
                errors.append(f"TYPED_ADAPTER_POLICIES policies[{index}] is invalid")
                continue
            policy_id = policy.get("policyID")
            adapter_id = policy.get("adapterID")
            for label, value, seen in (
                ("policyID", policy_id, policy_ids),
                ("adapterID", adapter_id, adapter_ids),
            ):
                if not isinstance(value, str) or not value:
                    errors.append(
                        f"TYPED_ADAPTER_POLICIES policies[{index}] lacks {label}"
                    )
                elif value in seen:
                    errors.append(f"TYPED_ADAPTER_POLICIES duplicates {label} {value}")
                else:
                    seen.add(value)
            operations = policy.get("operations")
            endpoints = policy.get("endpoints")
            graph = policy.get("endpointGraph")
            if not all(isinstance(value, list) for value in (operations, endpoints, graph)):
                errors.append(
                    f"TYPED_ADAPTER_POLICIES policy {policy_id} has invalid operations/endpoints/graph"
                )
                continue
            operation_ids = [value for value in operations if isinstance(value, str)]
            if len(operation_ids) != len(operations) or len(set(operation_ids)) != len(
                operation_ids
            ):
                errors.append(
                    f"TYPED_ADAPTER_POLICIES policy {policy_id} has missing or duplicate operations"
                )
            endpoint_ids = [
                value.get("endpointID")
                for value in endpoints
                if isinstance(value, dict) and isinstance(value.get("endpointID"), str)
            ]
            if len(endpoint_ids) != len(endpoints) or len(set(endpoint_ids)) != len(
                endpoint_ids
            ):
                errors.append(
                    f"TYPED_ADAPTER_POLICIES policy {policy_id} has missing or duplicate endpoint IDs"
                )
            allowed_nodes = set(endpoint_ids) | {"core"}
            graph_operations: set[str] = set()
            for edge_index, edge in enumerate(graph):
                if not isinstance(edge, dict):
                    errors.append(
                        f"TYPED_ADAPTER_POLICIES policy {policy_id} graph[{edge_index}] is invalid"
                    )
                    continue
                if edge.get("operation") not in operation_ids:
                    errors.append(
                        f"TYPED_ADAPTER_POLICIES policy {policy_id} graph[{edge_index}] references unknown operation"
                    )
                else:
                    graph_operations.add(edge["operation"])
                if edge.get("from") not in allowed_nodes or edge.get("to") not in set(
                    endpoint_ids
                ):
                    errors.append(
                        f"TYPED_ADAPTER_POLICIES policy {policy_id} graph[{edge_index}] references unknown endpoint"
                    )
            if graph_operations != set(operation_ids):
                errors.append(
                    f"TYPED_ADAPTER_POLICIES policy {policy_id} endpoint graph must cover every declared operation"
                )
            credentials = policy.get("credentials")
            scopes = credentials.get("scopes") if isinstance(credentials, dict) else None
            if not isinstance(scopes, list):
                errors.append(
                    f"TYPED_ADAPTER_POLICIES policy {policy_id} credentials.scopes must be an array"
                )
            else:
                scope_ids: set[str] = set()
                scope_by_endpoint: dict[str, str] = {}
                for scope_index, scope in enumerate(scopes):
                    if not isinstance(scope, dict):
                        errors.append(
                            f"TYPED_ADAPTER_POLICIES policy {policy_id} credential scope[{scope_index}] is invalid"
                        )
                        continue
                    scope_id = scope.get("scope")
                    if not isinstance(scope_id, str) or not scope_id:
                        errors.append(
                            f"TYPED_ADAPTER_POLICIES policy {policy_id} credential scope[{scope_index}] lacks an ID"
                        )
                    elif scope_id in scope_ids:
                        errors.append(
                            f"TYPED_ADAPTER_POLICIES policy {policy_id} duplicates credential scope {scope_id}"
                        )
                    else:
                        scope_ids.add(scope_id)
                    for endpoint_id in scope.get("endpointIDs", []):
                        if endpoint_id not in endpoint_ids:
                            errors.append(
                                f"TYPED_ADAPTER_POLICIES policy {policy_id} credential scope {scope_id} references unknown endpoint {endpoint_id}"
                            )
                        elif endpoint_id in scope_by_endpoint:
                            errors.append(
                                f"TYPED_ADAPTER_POLICIES policy {policy_id} endpoint {endpoint_id} appears in multiple credential scopes"
                            )
                        elif isinstance(scope_id, str):
                            scope_by_endpoint[endpoint_id] = scope_id
                for endpoint in endpoints:
                    if not isinstance(endpoint, dict):
                        continue
                    endpoint_id = endpoint.get("endpointID")
                    credential_scope = endpoint.get("credentialScope")
                    declared_scope = scope_by_endpoint.get(endpoint_id)
                    if credential_scope == "none":
                        if declared_scope is not None:
                            errors.append(
                                f"TYPED_ADAPTER_POLICIES policy {policy_id} endpoint {endpoint_id} is both uncredentialed and scope-bound"
                            )
                    elif credential_scope not in scope_ids:
                        errors.append(
                            f"TYPED_ADAPTER_POLICIES policy {policy_id} endpoint {endpoint_id} references unknown credential scope {credential_scope}"
                        )
                    elif declared_scope != credential_scope:
                        errors.append(
                            f"TYPED_ADAPTER_POLICIES policy {policy_id} endpoint {endpoint_id} credential scope is not bidirectionally declared"
                        )

    for collection_name, identity_key in (("wrappedDEKs", "domain"), ("stores", "id")):
        collection = projection.get(collection_name)
        if not isinstance(collection, list):
            errors.append(
                f"EXTENSION_KEYCHAIN_PROJECTION {collection_name} must be an array"
            )
            continue
        identities = [
            entry.get(identity_key)
            for entry in collection
            if isinstance(entry, dict) and isinstance(entry.get(identity_key), str)
        ]
        if len(identities) != len(collection) or len(set(identities)) != len(identities):
            errors.append(
                f"EXTENSION_KEYCHAIN_PROJECTION {collection_name} has missing or duplicate {identity_key} values"
            )

    global_wrapped_deks = keychain.get("wrappedDEKs")
    projected_wrapped_deks = projection.get("wrappedDEKs")
    if not isinstance(global_wrapped_deks, dict) or not isinstance(
        projected_wrapped_deks, list
    ):
        errors.append("Keychain authority/projection wrappedDEKs have invalid shapes")
    else:
        projected_by_domain = {
            entry.get("domain"): entry
            for entry in projected_wrapped_deks
            if isinstance(entry, dict) and isinstance(entry.get("domain"), str)
        }
        if set(projected_by_domain) != set(global_wrapped_deks):
            errors.append(
                "EXTENSION_KEYCHAIN_PROJECTION wrapped DEK domains must exactly match KEYCHAIN_POLICY"
            )
        for domain, global_entry in global_wrapped_deks.items():
            projected_entry = projected_by_domain.get(domain)
            if not isinstance(global_entry, dict) or not isinstance(
                projected_entry, dict
            ):
                continue
            comparisons = {
                "kekRef": global_entry.get("kekAccessGroup"),
                "dekScope": global_entry.get("scope"),
                "cryptoEraseTriggers": global_entry.get("cryptoEraseTriggers"),
            }
            for projected_key, expected in comparisons.items():
                if projected_entry.get(projected_key) != expected:
                    errors.append(
                        f"EXTENSION_KEYCHAIN_PROJECTION {domain}.{projected_key} "
                        "does not match KEYCHAIN_POLICY"
                    )
        for domain, projected_entry in projected_by_domain.items():
            if projected_entry.get("kekRef") not in global_groups:
                errors.append(
                    f"EXTENSION_KEYCHAIN_PROJECTION {domain} references unknown KEK group"
                )

    projected_stores = projection.get("stores")
    if isinstance(projected_stores, list):
        for store in projected_stores:
            if isinstance(store, dict) and store.get("ownerTarget") not in target_ids:
                errors.append(
                    f"EXTENSION_KEYCHAIN_PROJECTION store {store.get('id')} references unknown owner target"
                )

    market_endpoints = market_policy.get("endpoints")
    if not isinstance(market_endpoints, list):
        errors.append("MARKET_BROKER_POLICY endpoints must be an array")
    else:
        market_endpoint_ids = [
            entry.get("id")
            for entry in market_endpoints
            if isinstance(entry, dict) and isinstance(entry.get("id"), str)
        ]
        if len(market_endpoint_ids) != len(market_endpoints) or len(
            set(market_endpoint_ids)
        ) != len(market_endpoint_ids):
            errors.append("MARKET_BROKER_POLICY has missing or duplicate endpoint IDs")


def find_inventory(loaded: dict[Path, object]) -> tuple[Path, dict[str, object]] | None:
    for path, document in loaded.items():
        if path.name == "Typora能力清单.json" and isinstance(document, dict):
            return path, document
    return None


def check_inventory_references(loaded: dict[Path, object], errors: list[str]) -> None:
    inventory = find_inventory(loaded)
    if inventory is None:
        return
    path, document = inventory
    prd_path = DOCS / "产品" / "产品需求文档.md"
    prd_ids = set(REQUIREMENT_ID.findall(prd_path.read_text(encoding="utf-8")))
    entries = document.get("capabilities")
    if not isinstance(entries, list):
        errors.append(f"{path.relative_to(ROOT)}: capabilities must be an array")
        return
    seen: set[str] = set()
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            errors.append(f"{path.relative_to(ROOT)}: capabilities[{index}] must be an object")
            continue
        capability_id = entry.get("capabilityID")
        requirement_id = entry.get("requirementID")
        if not isinstance(capability_id, str) or not capability_id:
            errors.append(f"{path.relative_to(ROOT)}: capabilities[{index}] lacks capabilityID")
        elif capability_id in seen:
            errors.append(f"{path.relative_to(ROOT)}: duplicate capabilityID {capability_id}")
        else:
            seen.add(capability_id)
        if not isinstance(requirement_id, str) or requirement_id not in prd_ids:
            errors.append(
                f"{path.relative_to(ROOT)}: capabilities[{index}] references unknown requirementID {requirement_id!r}"
            )


def check_requirement_traceability(
    loaded: dict[Path, object], errors: list[str]
) -> None:
    path = DOCS / "治理" / "需求追踪.json"
    document = loaded.get(path)
    if not isinstance(document, dict):
        errors.append("文档/治理/需求追踪.json: missing machine source")
        return
    requirements = document.get("requirements")
    if not isinstance(requirements, dict):
        errors.append(f"{path.relative_to(ROOT)}: requirements must be an object")
        return
    prd_text = (DOCS / "产品" / "产品需求文档.md").read_text(encoding="utf-8")
    expected = set(REQUIREMENT_DEFINITION.findall(prd_text))
    actual = set(requirements)
    if expected != actual:
        errors.append(
            f"{path.relative_to(ROOT)}: PRD traceability mismatch; "
            f"missing={sorted(expected - actual)!r}, extra={sorted(actual - expected)!r}"
        )
    if document.get("expectedRequirementCount") != len(actual):
        errors.append(f"{path.relative_to(ROOT)}: expectedRequirementCount is stale")
    fixture_groups: set[str] = set()
    for requirement_id, mapping in requirements.items():
        if not isinstance(mapping, dict):
            errors.append(f"{path.relative_to(ROOT)}: {requirement_id} mapping is invalid")
            continue
        fixture_group = mapping.get("fixtureGroup")
        if not isinstance(fixture_group, str) or not fixture_group:
            errors.append(f"{path.relative_to(ROOT)}: {requirement_id} lacks fixtureGroup")
        elif fixture_group in fixture_groups:
            errors.append(
                f"{path.relative_to(ROOT)}: duplicate fixtureGroup {fixture_group}"
            )
        else:
            fixture_groups.add(fixture_group)
        references = mapping.get("evidenceRefs")
        if not isinstance(references, list) or not references:
            errors.append(f"{path.relative_to(ROOT)}: {requirement_id} lacks evidenceRefs")
            continue
        for reference in references:
            if not isinstance(reference, str) or any(mark in reference for mark in "*?[]"):
                errors.append(
                    f"{path.relative_to(ROOT)}: {requirement_id} has invalid evidenceRef {reference!r}"
                )
                continue
            if reference.startswith("docs/"):
                errors.append(
                    f"{path.relative_to(ROOT)}: {requirement_id} uses legacy path {reference}"
                )
            elif reference.startswith("文档/") and not (ROOT / reference).exists():
                errors.append(
                    f"{path.relative_to(ROOT)}: {requirement_id} references missing {reference}"
                )
        status = mapping.get("evidenceStatus")
        build_evidence = mapping.get("buildEvidence")
        if status in {"OPEN", "CONTRACT_FROZEN"} and build_evidence is not None:
            errors.append(
                f"{path.relative_to(ROOT)}: {requirement_id} has build evidence while {status}"
            )
        if status == "PASSED":
            if not isinstance(build_evidence, dict) or any(
                not isinstance(build_evidence.get(key), str)
                or not SHA256.fullmatch(build_evidence[key])
                for key in (
                    "releaseBuildSHA256",
                    "fixtureManifestSHA256",
                    "resultSHA256",
                )
            ):
                errors.append(
                    f"{path.relative_to(ROOT)}: {requirement_id} PASSED lacks real build evidence"
                )


def check_generated_inventory(errors: list[str]) -> None:
    generator = ROOT / "脚本" / "生成Typora能力清单视图.py"
    if not generator.is_file():
        errors.append("脚本/生成Typora能力清单视图.py: missing generator")
        return
    result = subprocess.run(
        [sys.executable, str(generator), "--check"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        errors.append(f"Typora generated-view/contract check failed: {detail}")


def check_frozen_hashes(node: object, location: str, errors: list[str]) -> None:
    if isinstance(node, dict):
        status = node.get("evidenceStatus", node.get("status"))
        frozen = isinstance(status, str) and status.upper() in {"FROZEN", "ACCEPTED"}
        for key, value in node.items():
            child = f"{location}.{key}"
            if frozen and key.lower().endswith(("hash", "sha256")):
                if not isinstance(value, str) or not SHA256.fullmatch(value):
                    errors.append(f"{child}: frozen evidence requires a real lowercase SHA-256")
            check_frozen_hashes(value, child, errors)
    elif isinstance(node, list):
        for index, value in enumerate(node):
            check_frozen_hashes(value, f"{location}[{index}]", errors)


def check_validator_self_tests(errors: list[str]) -> None:
    """Keep security-relevant schema keywords from silently becoming no-ops."""

    rejected_cases: list[tuple[str, object, dict[str, object]]] = [
        (
            "exclusiveMinimum",
            0,
            {"type": "number", "exclusiveMinimum": 0},
        ),
        (
            "exclusiveMaximum",
            1,
            {"type": "number", "exclusiveMaximum": 1},
        ),
        (
            "nonzero-sha256",
            "0" * 64,
            {
                "type": "string",
                "pattern": "^[0-9a-f]{64}$",
                "not": {"pattern": "^0{64}$"},
            },
        ),
        (
            "closed-object",
            {"known": True, "unknown": True},
            {
                "type": "object",
                "properties": {"known": {"type": "boolean"}},
                "additionalProperties": False,
            },
        ),
        (
            "composed-closed-object",
            {"common": 1, "kind": "event", "extensionID": "smuggled"},
            {
                "type": "object",
                "allOf": [
                    {
                        "properties": {"common": {"type": "integer"}},
                        "required": ["common"],
                    }
                ],
                "properties": {"kind": {"const": "event"}},
                "required": ["kind"],
                "unevaluatedProperties": False,
            },
        ),
    ]
    for name, instance, schema in rejected_cases:
        if not validate_schema_node(instance, schema, schema, f"self-test.{name}"):
            errors.append(f"JSON Schema validator self-test did not reject {name}")

    accepted_cases: list[tuple[str, object, dict[str, object]]] = [
        (
            "exclusive-range",
            0.5,
            {
                "type": "number",
                "exclusiveMinimum": 0,
                "exclusiveMaximum": 1,
            },
        ),
        (
            "nonzero-sha256",
            "1" + "0" * 63,
            {
                "type": "string",
                "pattern": "^[0-9a-f]{64}$",
                "not": {"pattern": "^0{64}$"},
            },
        ),
        (
            "composed-closed-object",
            {"common": 1, "kind": "event"},
            {
                "type": "object",
                "allOf": [
                    {
                        "properties": {"common": {"type": "integer"}},
                        "required": ["common"],
                    }
                ],
                "properties": {"kind": {"const": "event"}},
                "required": ["kind"],
                "unevaluatedProperties": False,
            },
        ),
    ]
    for name, instance, schema in accepted_cases:
        failures = validate_schema_node(instance, schema, schema, f"self-test.{name}")
        if failures:
            errors.append(
                f"JSON Schema validator self-test rejected {name}: {'; '.join(failures)}"
            )


def main() -> int:
    errors: list[str] = []
    check_validator_self_tests(errors)
    loaded = check_json(errors)
    check_schema_instances(loaded, errors)
    check_markdown_links(errors)
    check_prd_requirement_definitions(errors)
    check_inventory_references(loaded, errors)
    check_generated_inventory(errors)
    check_requirement_traceability(loaded, errors)
    check_declared_authority_paths(loaded, errors)
    check_machine_authority_cross_references(loaded, errors)
    for path, document in loaded.items():
        check_frozen_hashes(document, str(path.relative_to(ROOT)), errors)

    if errors:
        print("documentation contract validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print(
        f"validated {len(loaded)} JSON contracts, local JSON Schema instances, "
        "cross-authority references, and Markdown links"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

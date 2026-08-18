# P0–P3 Requirement Traceability

本文件说明 [机器追踪表](./REQUIREMENT_TRACEABILITY.json) 的权威边界和只读校验方法；字段、允许状态、P0–P3 全量 ID 集与 hash 约束以 [JSON Schema](./REQUIREMENT_TRACEABILITY.schema.json) 为权威。

## 权威边界

- [PRD](../product/PRD.md) 独占产品语义、版本归属与 DoD；追踪表不得改写产品要求。
- 追踪表独占 requirement ID 到 owner、工程阶段、精确证据引用、fixture group 和证据状态的工程映射。
- 机器源是 closed-world：当前恰好包含 PRD 中 68 个 `INF-P0-*`–`INF-P3-*` feature/DoD ID；`INF-SCOPE-*` 不属于 P0–P3 DoD，明确排除。
- requirement ID 是 `requirements` 对象的键。Schema 将 68 个允许键逐一列为 required，并拒绝未知键；同一 ID 不存在第二个合法映射位置。
- `evidenceRefs` 必须是精确文件或工件标识，不能包含 `*`、`?`、`[`、`]`。不得用目录通配符代替逐 requirement 映射。

## 状态语义

| `evidenceStatus` | 含义 | 能否计入 Release DoD |
| --- | --- | --- |
| `OPEN` | owner、阶段、合同引用和 fixture group 已冻结；尚无候选 Release 构建的完整机器证据 | 否 |
| `CONTRACT_FROZEN` | 仅适用于不声称运行行为的纯合同项；表示合同冻结，不表示实现或测试通过 | 否 |
| `PASSED` | 对同一候选 Release 构建执行对应 fixture，结果可由三个非零 SHA-256 复核 | 是 |

`PASSED` 必须提供 `buildEvidence.releaseBuildSHA256`、`fixtureManifestSHA256` 和 `resultSHA256`，每个值均为 64 位小写十六进制且不能全零。Schema 禁止 `OPEN` 或 `CONTRACT_FROZEN` 携带 `buildEvidence`，避免把占位 hash 误认为运行证据。

当前实例的 68 项全部为 `OPEN`。这表示逐项工程责任和验收入口已闭环，但 T0/P0 的 Release 构建、PID/entitlement、故障注入、性能、golden 和 postflight 证据仍未生成，不得据此宣布 T0、P0 或更高产品阶段完成。

## 变更协议

1. PRD 新增、替代或退役 P0–P3 ID 时，先完成产品评审。
2. 同一变更更新 Schema 的 `required`/`properties`、`expectedRequirementCount` 和追踪实例；不允许先合入未映射 ID。
3. owner 为唯一最终责任域；协作者和测试执行者记录在实际 fixture manifest，不在本表制造多 owner。
4. `engineeringPhases` 只表达实施/验证所在 T0–T6 阶段，不改变 P0–P3 产品版本。
5. fixture group 是稳定逻辑名；实际运行 manifest 必须绑定该值、精确候选构建和所有输入 hash。
6. 只有 CI 产出的 Release 证据完成复核后，才允许将状态改为 `PASSED` 并写入真实 hash。

## 只读校验

先运行仓库统一文档校验与 whitespace/diff 校验：

```sh
python3 scripts/validate_docs.py
git diff --check
```

以下只读检查从 PRD 重新抽取范围内 ID，并验证 machine source 的覆盖、唯一性、计数、阶段/类型一致性、当前无伪造通过状态和证据引用无通配符：

```sh
python3 - <<'PY'
import json
import pathlib
import re

root = pathlib.Path.cwd()
prd = (root / "docs/product/PRD.md").read_text(encoding="utf-8")
trace = json.loads((root / "docs/engineering/REQUIREMENT_TRACEABILITY.json").read_text(encoding="utf-8"))
expected = set(re.findall(r"INF-P[0-3]-(?:DOD|[A-Z0-9]+)-\d{3}", prd))
actual = set(trace["requirements"])
assert expected == actual, {"missing": sorted(expected - actual), "extra": sorted(actual - expected)}
assert len(actual) == trace["expectedRequirementCount"] == 68
assert all("INF-SCOPE-" not in requirement_id for requirement_id in actual)
for requirement_id, mapping in trace["requirements"].items():
    phase = requirement_id.split("-")[1]
    kind = "DOD" if "-DOD-" in requirement_id else "FEATURE"
    assert mapping["productPhase"] == phase
    assert mapping["requirementKind"] == kind
    assert mapping["evidenceStatus"] == "OPEN"
    assert "buildEvidence" not in mapping
    assert mapping["evidenceRefs"]
    assert not any(any(mark in ref for mark in "*?[]") for ref in mapping["evidenceRefs"])
print(f"traceability OK: {len(actual)} requirement IDs, all OPEN")
PY
```

安装有 Draft 2020-12 validator 的 CI 还必须使用 `REQUIREMENT_TRACEABILITY.schema.json` 验证实例。覆盖脚本不能替代 Schema；Schema 校验也不能替代 PRD 差集检查。

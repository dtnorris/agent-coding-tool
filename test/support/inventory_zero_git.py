#!/usr/bin/env python3
"""Reconcile saved TST-33 evidence and source without loading or running tests.

No subprocess API is used. Generated JSON is a review inventory, not acceptance.
Inputs are the original profiler artifact directory, script and accepted policy.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET
import zipfile

PREPARED = "194debd37badc94426d3757ee19a9db17df03e4c"
PROFILER_SHA = "694962657fa08f39c190405ad991cd77f8f9a755a3ce9b197d23477c9078b17b"


def digest(path):
    """Return a file's SHA-256; missing or unreadable input raises OSError."""
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def load(path):
    """Read JSON evidence; invalid or unavailable inputs propagate an error."""
    return json.loads(Path(path).read_text())


def save(path, value):
    """Write reproducible review JSON in the task-owned inventory directory."""
    path.write_text(json.dumps(value, indent=2, ensure_ascii=True) + "\n")


def require(condition, message):
    """Reject mismatched evidence even under Python -O; return nothing."""
    if not condition:
        raise ValueError(message)


def workbook_rows(archive, sheet):
    """Read inline XLSX cells from an original sheet without extra dependencies."""
    namespace = {"s": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
    tree = ET.fromstring(archive.read(f"xl/worksheets/sheet{sheet}.xml"))
    return [["".join(cell.itertext()) for cell in row]
            for row in tree.findall("s:sheetData/s:row", namespace)][1:]


def owner(path):
    """Assign migration responsibility from the whole-program file boundaries.

    This is responsibility, not inferred coverage: each row separately retains
    its actual method assertions, source ranges and measured line ownership.
    """
    name = Path(path).name
    if "feedback" in name:
        return "TST-43"
    if "apply_handoff" in name or "checkpoint" in name:
        return "TST-39"
    if any(token in name for token in ("delivery", "publisher")):
        return "TST-40"
    if any(token in name for token in ("retry", "recovery", "readiness", "worktree_manager", "icebox")):
        return "TST-38"
    return "TST-41"


def method_source(root, path, identity):
    """Extract a named existing method, its comments and assertion/loop sites.

    Enforces the repository's two-space test-method layout; ambiguous or changed
    layouts raise rather than silently mapping another method/class by filename.
    """
    lines = (root / path).read_text().splitlines()
    class_name, method = identity.split("#")
    starts = [index for index, line in enumerate(lines) if re.match(r"^  def " + re.escape(method) + r"(?:\W|$)", line)]
    require(len(starts) == 1, "ambiguous/missing method: " + identity)
    start = starts[0]
    classes = [line for line in lines[:start] if re.match(r"^class " + re.escape(class_name) + r" <", line)]
    require(classes, "class identity differs: " + identity)
    end = next(index for index in range(start + 1, len(lines)) if lines[index] == "  end")
    comments = []
    cursor = start - 1
    while cursor >= 0 and lines[cursor].startswith("  #"):
        comments.insert(0, lines[cursor].strip().removeprefix("# "))
        cursor -= 1
    assertions = [{"line": index + 1, "expression": lines[index].strip()}
                  for index in range(start, end + 1)
                  if re.search(r"\b(?:assert\w*|refute\w*|flunk)\b", lines[index])]
    scenarios = [{"line": index + 1, "expression": lines[index].strip()}
                 for index in range(start, end + 1)
                 if re.search(r"\b(?:each|each_with_index|times|stub|assert_raises)\b", lines[index])]
    return {"start_line": start + 1, "end_line": end + 1,
            "method_sha256": hashlib.sha256(("\n".join(lines[start:end + 1]) + "\n").encode()).hexdigest(),
            "purpose": comments or [method.removeprefix("test_").replace("_", " ")],
            "assertion_sites": assertions, "scenario_and_fault_sites": scenarios}


def census(root, paths):
    """Retain every lexical Git/process/fixture/status seam with exact source.

    Overinclusive comment/string matches are labeled lexical, never claimed to
    prove runtime calls. Source hashes and method context support manual review
    of dynamic argv and inline child scripts, rather than filename heuristics.
    """
    patterns = {
        "git_reference": r"git",
        "process_transport": r"capture[23]?|popen|spawn|\bexec\b|\bsystem\b|`|\bfork\b|PTY",
        "fixture_copy_or_metadata": r"cp_r|\.git|git_seed|fixture_command_path|xcrun",
        "cached_native_or_status": r"\.method\(:(?:capture3|spawn)|Process::Status|def (?:self\.)?status|\.pid\b",
        "environment_or_payload": r"RUBYOPT|GIT_[A-Z_]+|stdin_data|validation|transport|timeout|pgroup",
    }
    result = []
    for path in paths:
        method = None
        for number, line in enumerate((root / path).read_text().splitlines(), 1):
            if re.match(r"\s*def ", line):
                method = line.strip()
            kinds = [kind for kind, pattern in patterns.items() if re.search(pattern, line, re.I if kind == "git_reference" else 0)]
            if kinds:
                result.append({"path": path, "line": number, "kinds": kinds,
                               "preceding_method_declaration": method, "source": line})
    return result


def build(root, artifacts, profiler, policy):
    """Reconcile all original identities, workbook files, policy and node maps.

    Raises on any inconsistent required evidence. Produces task-owned source
    inventories only; it neither changes manifests/policy nor runs test cases.
    """
    required = load(root / "test/required_cases.json")
    ordinary = load(root / "test/ordinary_cases.json")
    native = required["native_default"]
    require(set(ordinary) | set(native) == set(required["default"]), "default file partition differs")
    for pattern, files in [("test/**/*_test.rb", required["default"]),
                           ("test/integration/*_git_integration.rb", required["integration"]),
                           ("test/git_contract/**/*_contract.rb", load(root / "test/git_contract/required_cases.json"))]:
        require({str(path.relative_to(root)) for path in root.glob(pattern)} == set(files), "source discovery differs: " + pattern)
    layers = {"ordinary": {path: list(cases) for path, cases in ordinary.items()},
              "git_contract": load(root / "test/git_contract/required_cases.json"),
              "native_default": native, "native_integration": required["integration"]}
    for path, cases in required["default"].items():
        members = list(ordinary.get(path, {})) + native.get(path, [])
        require(sorted(cases) == sorted(members) and len(set(members)) == len(members), "partition mismatch: " + path)
    expected = {(layer, path, case) for layer, files in layers.items() for path, cases in files.items() for case in cases}
    require(len(expected) == sum(len(cases) for files in layers.values() for cases in files.values()) == 459, "459 identities required")
    measurements = load(artifacts / "measurements.json")
    measured = {(row["layer"], row["file"], row["case"]): row for row in measurements["tests"]}
    require(len(measurements["tests"]) == len(measured) == 459 and set(measured) == expected, "saved case identities differ")
    require(all(row["status"] == "pass" for row in measured.values()), "saved nonpassing case")
    with zipfile.ZipFile(artifacts / "ACT-test-profile.xlsx") as workbook:
        files, tests = workbook_rows(workbook, 1), workbook_rows(workbook, 2)
    require(len(files) == 43 and {row[0] for row in files} == {key[1] for key in expected}, "43 workbook files differ")
    require(len(tests) == 459 and {(row[5], row[0], row[4]) for row in tests} == expected, "workbook cases differ")
    for row in files:
        members = [value for key, value in measured.items() if key[1] == row[0]]
        require(row[4] == f"{len(members)} / {len(members)}" and row[5] == "pass", "workbook file count/status differs")
        require(abs(float(row[1]) - sum(member["seconds"] for member in members)) < 1e-8, "workbook time differs")
    report = load(artifacts / "official-report.json")
    require(digest(profiler) == PROFILER_SHA, "original profiler hash differs")
    require(digest(policy) == report["policy_sha256"], "saved accepted policy hash differs")
    require(report["accepted"] and report["complete_offline_gate"], "saved report is not accepted")
    processes = [process for stage in report["stages"] for process in stage["processes"]]
    require(sum(process["tests"] for process in processes) == 459 and
            sum(process["assertions"] for process in processes) == sum(row["assertions"] for row in measured.values()) and
            all(process["complete"] and process["exit_status"] == 0 and process["signal"] is None for process in processes),
            "saved official process totals/outcomes differ")
    contexts = [load(path) for path in sorted(artifacts.glob("*.context.json"))]
    require(len(contexts) == 16, "saved suite context census differs")
    first = contexts[0]
    require(all(context["invocation"] == report["invocation"] and context["sources"] == report["sources"] and
                context["layout"] == first["layout"] for context in contexts), "saved contexts differ")
    require(all(digest(root / path) == sha for path, sha in report["sources"].items()), "production moved; coordinates require reconciliation")
    covered = {}
    for path, layout in first["layout"].items():
        uncovered = set(report["coverage"]["combined"]["uncovered"][path])
        require(uncovered <= set(layout), "unknown uncovered nodes")
        covered[path] = sorted(set(layout) - uncovered)
    for kind in ("line", "branch"):
        require(sum(sum(node.startswith(kind + ":") for node in nodes) for nodes in covered.values()) ==
                report["coverage"]["combined"][kind]["covered"], "covered-node counts differ")
    output = root / "test/coverage"
    recovered = {"schema": "act-zero-git-baseline-nodes/v1", "invocation": report["invocation"],
                 "source_files": report["sources"], "covered": covered,
                 "derivation": "saved suite layout keys minus official combined uncovered keys; counts checked",
                 "per_case_branch_nodes": "UNAVAILABLE: observer captured line increases only"}
    save(output / "zero_git_baseline_nodes.json", recovered)
    rows = []
    for key in sorted(expected):
        layer, path, case = key
        observation = measured[key]
        source = method_source(root, path, case)
        hits = observation["hits"]
        rows.append({"layer": layer, "file": path, "case": case, "replacement_case": case,
                     "migration_owner": owner(path), "disposition": "retain identity and assertion purposes; migration pending",
                     **source, "negative_control": {"status": "REQUIRED_NOT_RUN",
                         "owner": owner(path), "fault_contract": "See zero-git-migration.md capability controls; each retained assertion must fail when its asserted effect is deliberately violated",
                         "existing_fault_sites": [site for site in source["scenario_and_fault_sites"] if "stub" in site["expression"] or "assert_raises" in site["expression"]]},
                     "baseline_coverage": {"owner": owner(path), "line_hits": len(hits),
                         "files": sorted({hit[0] for hit in hits}),
                         "hits_sha256": hashlib.sha256(json.dumps(hits, separators=(",", ":")).encode()).hexdigest(),
                         "artifact": "measurements.json", "lookup": list(key), "branch_nodes": "UNAVAILABLE per case"},
                     "saved_assertions": observation["assertions"], "saved_seconds": observation["seconds"]})
    paths = sorted(str(path.relative_to(root)) for folder in ("lib", "test") for path in (root / folder).rglob("*.rb"))
    paths += ["Rakefile", "bin/agent-coding-tool", "test/profile_zero_git.py"]
    original = load(artifacts / "before.json")
    drift = [path for path, sha in original["source_sha256"].items() if not (root / path).is_file() or digest(root / path) != sha]
    inventory = {"schema": "act-zero-git-inventory/v1", "prepared_sha": PREPARED,
                 "authority": "plans/TST-33-45-fast-suite.txt in prepared ACTD; TST-45 owns integration/acceptance",
                 "source_files": {path: digest(root / path) for path in paths + [
                     "test/required_cases.json", "test/ordinary_cases.json", "test/git_contract/required_cases.json",
                     "test/support/zero_git_required_cases.json"]},
                 "artifacts": {path.name: digest(path) for path in [profiler, policy, artifacts / "ACT-test-profile.xlsx",
                     artifacts / "measurements.json", artifacts / "official-report.json", artifacts / "observer.rb",
                     artifacts / "before.json", artifacts / "after.json"]},
                 "saved_reference": {"head": report["head"], "assertions": sum(row["assertions"] for row in measured.values()),
                     "outer_seconds": report["outer_seconds"], "profiled_wall_seconds": dict(measurements["metadata"])["Total suite elapsed (seconds)"],
                     "coverage": {kind: report["coverage"]["combined"][kind] for kind in ("line", "branch")},
                     "conditions": report["conditions"], "runtime_comparison": report["runtime_comparison"],
                     "coverage_expectations": report["coverage_expectations"], "source_drift_from_profile": drift},
                 "layer_counts": {layer: sum(len(cases) for cases in files.values()) for layer, files in layers.items()},
                 "workbook_file_rows": files, "cases": rows, "lexical_effect_locations": census(root, paths),
                 "original_profiler_effect_locations": census(profiler.parent, [profiler.name]),
                 "limits": ["Static census is overinclusive; dynamic envelopes remain source-bound contracts, not observed execution counts",
                     "No native tests run; retained case migration and deliberate-fault execution belong to subsequent owners",
                     "Per-case branch attribution unavailable; aggregate exact nodes recovered on unchanged production only",
                     "No new policy acceptance/reference; supplied saved PASS is historical, not candidate acceptance"]}
    save(output / "zero_git_inventory.json", inventory)
    print(json.dumps({"cases": len(rows), "files": len(files), "layers": inventory["layer_counts"],
                      "saved_assertions": inventory["saved_reference"]["assertions"], "effect_locations": len(inventory["lexical_effect_locations"]),
                      "production_drift": [], "profile_source_drift": drift, "aggregate_nodes": {kind: report["coverage"]["combined"][kind]["covered"] for kind in ("line", "branch")}}))


def main():
    """Parse explicit evidence locations and generate the baseline-bound census."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--artifacts", type=Path, required=True)
    parser.add_argument("--profiler", type=Path, required=True)
    parser.add_argument("--policy", type=Path, required=True)
    args = parser.parse_args()
    build(args.root.resolve(), args.artifacts.resolve(), args.profiler.resolve(), args.policy.resolve())


if __name__ == "__main__":
    main()

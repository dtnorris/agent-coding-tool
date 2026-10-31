#!/usr/bin/env python3
"""Guarded migration of the saved ACT profiler; observer bytes are unchanged.

Original wrapper SHA256: 694962657fa08f39c190405ad991cd77f8f9a755a3ce9b197d23477c9078b17b
Only TST-45 owns full runs after all families and parent permits are integrated.
Current unmigrated harness launches fail closed; use --inspect-only in TST-33.
Run ACT's test:all command and export per-case/file measurements.

Requires the checkout's existing Ruby/Bundler dependencies and Python 3.9+.
All profiler files go outside the repository. No dependencies are installed.
Coverage is line coverage during each test, including observed cold children;
shared pre-test loading is excluded. Overlapping coverage is not additive.
"""
import argparse
import base64
import collections
import datetime
import hashlib
import io
import json
import math
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
import zipfile

OBSERVER = r'''# frozen_string_literal: true

# External diagnostic observer for ACT's existing covered test:all runner.
# No coverage counters are cleared and no runner/gate methods are replaced.
require "json"
require "coverage"

module ACTTestObserver
  # Returns a monotonic timestamp; OS clock errors propagate.
  def self.clock
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # Appends one complete JSON record to the current suite's private journal.
  # IO errors are surfaced on stderr and leave missing evidence in the exporter.
  def self.write(record)
    File.open(@journal, "ab", 0o600) { |file| file.write(JSON.generate(record) + "\n") }
  rescue StandardError => error
    warn "ACT test observer: #{error.class}: #{error.message}"
  end

  # Reads canonical source line counters without stopping/resetting Coverage.
  # Returns path=>counter arrays. Missing coverage or changed layouts raise.
  def self.snapshot
    raise "ACT coverage is not running" unless Coverage.running?
    observed = Coverage.peek_result
    observed.each do |absolute, values|
      source = @context.fetch("sources").keys.find { |path| absolute.end_with?("/#{path}") }
      next unless source && absolute != File.join(@context.fetch("root"), source)
      if values.fetch(:lines).compact.any?(&:positive?)
        raise "additional source copy executed in suite interpreter; per-test attribution unavailable"
      end
    end
    @context.fetch("sources").to_h do |path, _digest|
      lines = observed.fetch(File.join(@context.fetch("root"), path)).fetch(:lines)
      actual = lines.each_index.select { |index| !lines[index].nil? }.map { |index| "line:#{index + 1}" }
      expected = @context.fetch("layout").fetch(path).keys.grep(/^line:/)
      raise "line layout changed: #{path}" unless actual.sort == expected.sort
      [path, lines.dup]
    end
  end

  # Returns child interpreter marker prefixes from the official coverage store.
  def self.children
    Dir.glob(File.join(@context.fetch("directory"), "*.started")).reject do |path|
      JSON.parse(File.binread(path)).fetch("pid") == Process.pid
    end.map { |path| path.delete_suffix(".started") }
  end

  # Captures the pre-test counters and child inventory; observation errors are
  # retained as missing coverage while the real test is allowed to execute.
  def self.before(test)
    raise "parallel test attribution is unsupported" if @active
    @active = true
    token = { "case" => "#{test.class.name}##{test.name}", "errors" => [],
              "source" => test.method(test.name).source_location&.first,
              "inside" => ENV["ACT_PROFILE_INSIDE_CASE"] }
    ENV["ACT_PROFILE_INSIDE_CASE"] = "1"
    begin
      token["before"] = snapshot
      token["children_before"] = children
    rescue StandardError => error
      token["errors"] << "#{error.class}: #{error.message}"
    end
    token["started"] = clock
    token
  end

  # Records elapsed test time, result and increased source counters. New child
  # evidence is associated with this test only when born inside its boundary.
  # Export later verifies every child's identity and completion independently.
  def self.after(test, result, token, exception)
    elapsed = clock - token.fetch("started")
    begin
      observed = snapshot
      hits = {}
      if token["before"]
        observed.each do |path, lines|
          previous = token.fetch("before").fetch(path)
          raise "coverage counter reset: #{path}" if lines.each_index.any? { |index|
            lines[index] && lines[index] < previous.fetch(index) }
          hits[path] = lines.each_index.filter_map { |index|
            index + 1 if lines[index] && lines[index] > previous.fetch(index) }
        end
      end
      new_children = children - token.fetch("children_before", [])
      child_rows = new_children.map { |prefix| { "prefix" => prefix, "finished_at_test_end" => File.file?("#{prefix}.json") } }
    rescue StandardError => error
      token["errors"] << "#{error.class}: #{error.message}"
    end
    status = if exception
      "interrupted"
    elsif result
      result.skipped? ? "skip" : result.error? ? "error" : result.passed? ? "pass" : "failure"
    else
      "incomplete"
    end
    write("case" => token.fetch("case"), "source" => token["source"],
          "seconds" => result&.time || elapsed, "status" => status,
          "assertions" => result&.assertions, "hits" => hits || {},
          "children" => child_rows || [], "errors" => token.fetch("errors"),
          "pid" => Process.pid, "context_file" => @context_file)
  ensure
    ENV["ACT_PROFILE_INSIDE_CASE"] = token["inside"]
    @active = false
  end

  # Installs only in a top-level selected suite at the requested source root.
  # Cold children and nested verifier fixtures keep ACT's own coverage preload.
  def self.install
    return unless ENV["ACT_PROFILE_OUTPUT"] && ENV["ACT_COVERAGE_CONTEXT"] && ENV["ACT_SUITE_SELECTION"]
    return if ENV["ACT_PROFILE_INSIDE_CASE"]
    @context_file = ENV.fetch("ACT_COVERAGE_CONTEXT")
    @context = JSON.parse(File.binread(@context_file))
    return unless File.realpath(@context.fetch("root")) == ENV.fetch("ACT_PROFILE_ROOT")
    @selected = ENV.fetch("ACT_SUITE_SELECTION").split("\n")
    require "minitest/test"
    @journal = File.join(ENV.fetch("ACT_PROFILE_OUTPUT"), "suite-#{Process.pid}.jsonl")
    info = @context.merge("suite_pid" => Process.pid, "context_file" => @context_file,
                          "selected" => @selected, "journal" => @journal)
    File.write(File.join(ENV.fetch("ACT_PROFILE_OUTPUT"), "suite-#{Process.pid}.context.json"), JSON.generate(info), mode: "wx")
    Minitest::Test.prepend(Measurement)
  end

  # Returns true for this suite's expected test identities, excluding nested tests.
  def self.selected?(test)
    selected = @selected.include?("#{test.class.name}##{test.name}")
    write("observer_error" => "overlapping selected tests; per-test coverage unavailable") if selected && @active
    selected && !@active
  end

  module Measurement
    # Delegates the original Minitest run, preserving its return and exceptions.
    # Observation surrounds setup/test/teardown and never changes gate outcomes.
    def run
      return super unless ACTTestObserver.selected?(self)
      token = ACTTestObserver.before(self)
      result = nil
      begin
        result = super
      ensure
        ACTTestObserver.after(self, result, token, $!)
      end
      result
    end
  end
end

ACTTestObserver.install
'''
TEMPLATE = "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"
FAMILIES = {
    "LIFE": "Task definitions and lifecycle",
    "VIS": "Work visibility and scheduling advice",
    "PREP": "Task preparation and worker instructions",
    "REP": "Repository workspaces and isolation",
    "WRK": "Concurrent work and external-agent coordination",
    "WRKL": "Worker launching and process supervision",
    "EVD": "Run evidence and controlled inspection",
    "VALD": "Candidate checkpoints and validation receipts",
    "REC": "Attempt recovery, retries, and cleanup",
    "PATCH": "Patch handoff and local application",
    "DRAFT": "Trusted validation and draft-PR delivery",
    "DATA": "ACT task-data publication",
}
FILE_FAMILIES = {
    "apply_handoff_test.rb": "PATCH", "apply_handoff_git_integration.rb": "PATCH",
    "attempt_recovery_test.rb": "REC", "attempt_retry_git_integration.rb": "REC",
    "ordinary_boundary_test.rb": "VALD", "feedback_contract.rb": "VALD",
    "launcher_fixture_test.rb": "WRKL", "launcher_test.rb": "WRKL",
    "icebox_test.rb": "LIFE", "icebox_git_integration.rb": "LIFE",
    "coding_skill_test.rb": "PREP", "planning_guidance_test.rb": "PREP",
    "prompt_renderer_test.rb": "PREP", "config_test.rb": "LIFE, REP",
    "external_activity_test.rb": "WRK", "family_status_test.rb": "VIS",
    "live_write_collision_status_test.rb": "VIS, WRK", "next_test.rb": "VIS",
    "parallel_launch_test.rb": "WRK, WRKL", "preflight_recovery_test.rb": "REC",
    "publisher_test.rb": "DATA", "publisher_git_integration.rb": "DATA",
    "ready_unlock_metrics_test.rb": "VIS", "repo_inspector_test.rb": "PREP",
    "retry_liveness_test.rb": "REC", "state_store_test.rb": "LIFE",
    "status_next_summary_test.rb": "VIS", "task_store_test.rb": "LIFE",
    "worktree_manager_test.rb": "REP", "write_collision_test.rb": "WRK",
    "run_evidence_test.rb": "EVD", "evidence_tunnel_test.rb": "EVD",
    "tunnel_credential_test.rb": "EVD", "checkpoint_git_integration.rb": "VALD",
    "delivery_manager_git_integration.rb": "DRAFT", "multi_delivery_git_integration.rb": "DRAFT",
    "parallel_delivery_git_integration.rb": "WRK, DRAFT",
    "manual_parallel_launch_git_integration.rb": "WRK, WRKL",
    "readiness_git_integration.rb": "VIS, PREP",
    "incidental_metadata_test.rb": "REP, VALD, REC, DATA",
    "native_contract.rb": "PREP, REP, WRKL, PATCH, DATA",
}
NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
ET.register_namespace("", NS)


def read_json(path):
    """Read one UTF-8 JSON document; decoding and filesystem errors propagate."""
    return json.loads(Path(path).read_text())


def save_json(path, value):
    """Save a new diagnostic JSON document without overwriting an existing file."""
    with Path(path).open("x") as stream:
        json.dump(value, stream, indent=2, ensure_ascii=True)
        stream.write("\n")


def fingerprint(repo):
    """Read actual source identity through a guarded, read-only Ruby reader.

    Git status semantics and executable version are unavailable. Exact metadata
    and source hashes replace them; this changes baseline comparator conditions.
    """
    reader = repo / "test/support/source_identity.rb"
    guard = repo / "test/support/no_git_execution.rb"
    result = subprocess.check_output(["ruby", "-r", str(guard), str(reader), str(repo)],
                                     cwd=repo, env=dict(os.environ, RUBYOPT=""))
    identity = json.loads(result)
    if identity["root"] != str(repo) or identity["availability"] != "AVAILABLE":
        raise ValueError("source provenance unavailable: " + identity.get("reason", "root mismatch"))
    identity["source_sha256"] = identity.pop("source_files")
    return identity


def inventory(repo):
    """Read current ordinary/native/contract manifests and validate their partition."""
    required = read_json(repo / "test/required_cases.json")
    ordinary = read_json(repo / "test/ordinary_cases.json")
    native = required["native_default"]
    if set(ordinary) | set(native) != set(required["default"]):
        raise ValueError("ordinary/native file partition differs from required inventory")
    for path, cases in required["default"].items():
        selected = list(ordinary.get(path, {})) + native.get(path, [])
        if sorted(selected) != sorted(cases) or len(selected) != len(set(selected)):
            raise ValueError("ordinary/native case partition differs: " + path)
    layers = [("ordinary", ordinary), ("git_contract", read_json(repo / "test/git_contract/required_cases.json")),
              ("native_default", native), ("native_integration", required["integration"])]
    result = {}
    for layer, files in layers:
        for path, cases in files.items():
            if not (repo / path).is_file():
                raise ValueError("missing required test file: " + path)
            for case in cases:
                key = (layer, case)
                if key in result:
                    raise ValueError("duplicate expected identity: " + repr(key))
                result[key] = path
    return result


def family(path, case):
    """Assign reviewed test-purpose categories; unfamiliar files remain UNMAPPED."""
    name = Path(path).name
    test = case.split("#", 1)[-1]
    if name == "native_contract.rb":
        if re.search(r"skill|snapshot|remote_requests", test):
            return "PREP"
        if "commit_contents" in test:
            return "DRAFT, DATA"
        if "worktree" in test:
            return "REP"
        if "process" in test:
            return "WRKL"
        if "nul_status" in test:
            return "PATCH, DATA"
        return "VALD"
    if name == "cli_test.rb":
        if "prepare" in test:
            return "PREP"
        if re.search(r"status|dashboard|headline|column|blocked_tasks|ready_tasks|candidate_moves|completion_filter", test):
            return "VIS"
        return "LIFE"
    if name == "coordinator_test.rb":
        if re.search(r"prepare|snapshot|fresh|stale|pushed|read_only|remote", test):
            return "PREP"
        if re.search(r"collision|overlap|reservation", test):
            return "WRK"
        return "LIFE"
    return FILE_FAMILIES.get(name, "UNMAPPED")


def join_families(values):
    """Return distinct category codes in the user's original order."""
    codes = {code for value in values for code in value.split(", ")}
    return ", ".join([code for code in FAMILIES if code in codes] + (["UNMAPPED"] if "UNMAPPED" in codes else []))


def child_hits(child, context):
    """Validate one official child coverage result and return executed line keys.

    A killed fixture-only child contributes nothing. Missing ACT-executing or
    cross-test child evidence raises rather than being presented as zero coverage.
    """
    prefix = child["prefix"]
    active = Path(prefix + ".active").is_file()
    path = Path(prefix + ".json")
    if not path.is_file():
        if active:
            raise ValueError("unfinished ACT child")
        return set()
    record = read_json(path)
    for key in ("invocation", "selection", "stage", "sources"):
        if record[key] != context[key]:
            raise ValueError("child identity mismatch: " + key)
    if record["pid"] != read_json(prefix + ".started")["pid"] or record["active"] != active:
        raise ValueError("child PID/execution marker mismatch")
    if active and not child["finished_at_test_end"]:
        raise ValueError("ACT child outlived test; attribution unavailable")
    if set(record["files"]) != set(context["sources"]):
        raise ValueError("child production denominator incomplete")
    hits = set()
    for source, nodes in record["files"].items():
        if set(nodes) != set(context["layout"][source]):
            raise ValueError("child executable layout mismatch")
        if any(type(count) is not int or count < 0 for count in nodes.values()):
            raise ValueError("invalid child hit counter")
        hits.update((source, int(node[5:])) for node, count in nodes.items() if node.startswith("line:") and count > 0)
    return hits


def collect(repo, output, expected):
    """Reconcile observed cases, coverage and missing tests against current manifests."""
    rows, problems, contexts = {}, [], []
    canonical_sources = canonical_layout = None
    denominator = None
    for path in sorted(output.glob("suite-*.context.json")):
        context = read_json(path)
        contexts.append(context)
        if canonical_sources is None:
            canonical_sources, canonical_layout = context["sources"], context["layout"]
            denominator = sum(node.startswith("line:") for nodes in canonical_layout.values() for node in nodes)
        if context["sources"] != canonical_sources or context["layout"] != canonical_layout:
            raise ValueError("production denominator changed between suites")
        journal = Path(context["journal"])
        records = [json.loads(line) for line in journal.read_text().splitlines()] if journal.is_file() else []
        assigned = [child["prefix"] for row in records for child in row.get("children", [])]
        ambiguity = len(assigned) != len(set(assigned))
        for started in Path(context["directory"]).glob("*.started"):
            prefix = str(started)[:-8]
            if read_json(started)["pid"] != context["suite_pid"] and Path(prefix + ".active").is_file() and prefix not in assigned:
                ambiguity = True
        for row in records:
            if "observer_error" in row:
                problems.append(row["observer_error"])
                ambiguity = True
        for row in records:
            if "case" not in row:
                continue
            key = (context["stage"], row["case"])
            if key in rows or key not in expected:
                raise ValueError("duplicate or unregistered observed test: " + repr(key))
            path = expected[key]
            errors = list(row["errors"])
            hits = {(source, line) for source, lines in row["hits"].items() for line in lines}
            try:
                if row["pid"] != context["suite_pid"] or row["context_file"] != context["context_file"]:
                    raise ValueError("observer suite identity mismatch")
                if ambiguity:
                    raise ValueError("unattributed or overlapping child/test execution in suite")
                if row["source"] and Path(row["source"]).resolve().is_relative_to(repo):
                    path = str(Path(row["source"]).resolve().relative_to(repo))
                if not isinstance(row["seconds"], (int, float)) or not math.isfinite(row["seconds"]) or row["seconds"] < 0:
                    raise ValueError("invalid elapsed time")
                for child in row["children"]:
                    hits |= child_hits(child, context)
                if any(source not in canonical_layout or "line:" + str(line) not in canonical_layout[source] for source, line in hits):
                    raise ValueError("hits outside executable denominator")
            except (ValueError, KeyError, OSError) as error:
                errors.append(str(error))
            coverage = len(hits) / denominator if not errors and denominator else None
            rows[key] = {"file": path, "seconds": row["seconds"], "coverage": coverage,
                         "family": family(path, row["case"]), "case": row["case"], "layer": context["stage"],
                         "status": row["status"], "coverage_detail": "; ".join(errors) if errors else f"{len(hits)} / {denominator} executable lines",
                         "hits": sorted(hits), "assertions": row.get("assertions")}
            if errors:
                problems.append(row["case"] + ": " + "; ".join(errors))
    for (layer, case), path in expected.items():
        if (layer, case) not in rows:
            rows[layer, case] = {"file": path, "seconds": None, "coverage": None, "family": family(path, case),
                                 "case": case, "layer": layer, "status": "not run", "coverage_detail": "No observed result", "hits": []}
    return list(rows.values()), contexts, denominator, problems


def column_name(index):
    """Convert a one-based column number to its Excel letters."""
    result = ""
    while index:
        index, digit = divmod(index - 1, 26)
        result = chr(65 + digit) + result
    return result


def worksheet(template, values):
    """Populate an artifact-tool-authored worksheet with typed measured values.

    Uses only Python's ZIP/XML standard library on the user's Mac. Header styles,
    widths, frozen panes and numeric formats come from the embedded template.
    """
    root = ET.fromstring(template)
    data = root.find(f"{{{NS}}}sheetData")
    prototypes = data.findall(f"{{{NS}}}row")
    styles = {int(row.attrib["r"]): {re.sub(r"\d", "", cell.attrib["r"]): cell.get("s", "0") for cell in row} for row in prototypes}
    for row in list(data):
        data.remove(row)
    for number, row_values in enumerate(values, 1):
        height = 32 if number == 1 else 22
        if number > 1 and len(row_values) == 2:
            value = str(row_values[1])
            height = max(22, min(150, 16 * max(len(value.splitlines()), math.ceil(len(value) / 110))))
        elif number > 1 and len(row_values) == 8:
            height = max(22, min(64, 16 * math.ceil(len(str(row_values[4])) / 100)))
        row = ET.SubElement(data, f"{{{NS}}}row", r=str(number), ht=str(height), customHeight="1")
        for index, value in enumerate(row_values, 1):
            col = column_name(index)
            cell = ET.SubElement(row, f"{{{NS}}}c", r=f"{col}{number}", s=styles.get(1 if number == 1 else 2, {}).get(col, "0"))
            if value is None:
                value = "N/A"
            if isinstance(value, (float, int)) and not isinstance(value, bool):
                ET.SubElement(cell, f"{{{NS}}}v").text = str(value)
            else:
                cell.set("t", "inlineStr")
                text = ET.SubElement(ET.SubElement(cell, f"{{{NS}}}is"), f"{{{NS}}}t")
                text.text = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f]", "", str(value))[:32767]
                text.set("{http://www.w3.org/XML/1998/namespace}space", "preserve")
    reference = f"A1:{column_name(max(map(len, values)))}{len(values)}"
    dimension = root.find(f"{{{NS}}}dimension")
    if dimension is not None:
        dimension.set("ref", reference)
    auto_filter = ET.Element(f"{{{NS}}}autoFilter", ref=reference)
    root.insert(list(root).index(data) + 1, auto_filter)
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


def write_workbook(path, rows, metadata, denominator):
    """Export file aggregates, individual cases and run/methodology into XLSX."""
    groups = collections.defaultdict(list)
    for row in rows:
        groups[row["file"]].append(row)
    files = [["Repo path to test file", "Observed test time (seconds)", "Codebase line coverage", "Feature family/category", "Tests observed / expected", "Result"]]
    for filename, members in sorted(groups.items(), key=lambda item: -sum(row["seconds"] or 0 for row in item[1])):
        observed = [row for row in members if row["seconds"] is not None]
        hits = {tuple(hit) for row in members for hit in row["hits"]}
        coverage = len(hits) / denominator if denominator and all(row["coverage"] is not None for row in members) else None
        status = "pass" if all(row["status"] == "pass" for row in members) else ", ".join(sorted({row["status"] for row in members}))
        files.append([filename, sum(row["seconds"] for row in observed) if observed else None, coverage,
                      join_families(row["family"] for row in members), f"{len(observed)} / {len(members)}", status])
    tests = [["Repo path to test file", "Observed test time (seconds)", "Codebase line coverage", "Feature family/category", "Test case", "Suite layer", "Result", "Coverage detail"]]
    tests += [[row[key] for key in ("file", "seconds", "coverage", "family", "case", "layer", "status", "coverage_detail")]
              for row in sorted(rows, key=lambda row: -(row["seconds"] or 0))]
    run = [["Run detail", "Value"]] + [[key, value] for key, value in metadata]
    run += [["Category " + code, title] for code, title in FAMILIES.items()]
    with zipfile.ZipFile(io.BytesIO(base64.b64decode(TEMPLATE))) as source, zipfile.ZipFile(path, "x", zipfile.ZIP_DEFLATED) as destination:
        replacements = {f"xl/worksheets/sheet{i}.xml": worksheet(source.read(f"xl/worksheets/sheet{i}.xml"), values)
                        for i, values in enumerate((files, tests, run), 1)}
        for entry in source.infolist():
            destination.writestr(entry, replacements.get(entry.filename, source.read(entry.filename)))


def run_suite(repo, output):
    """Run exactly one canonical full suite, preserving output bytes and exit status."""
    hook = output / "observer.rb"
    hook.write_text(OBSERVER)
    environment = dict(os.environ, ACT_PROFILE_ROOT=str(repo), ACT_PROFILE_OUTPUT=str(output), BUNDLE_FROZEN="true")
    environment["RUBYOPT"] = shlex.join(["-r" + str(repo / "test/support/no_git_execution.rb"), "-r" + str(hook), *shlex.split(environment.get("RUBYOPT", ""))])
    print("Running: bundle exec rake test:all", flush=True)
    print("Profiling adds overhead; results are diagnostic. Output: " + str(output), flush=True)
    begun = time.perf_counter()
    with (output / "suite.log").open("xb") as log:
        process = subprocess.Popen(["bundle", "exec", "rake", "test:all"], cwd=repo, env=environment,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        try:
            while True:
                block = process.stdout.read1(65536)
                if not block:
                    break
                log.write(block)
                sys.stdout.buffer.write(block)
                sys.stdout.buffer.flush()
            code = process.wait()
        except KeyboardInterrupt:
            # Signal only the newly created Rake process. ACT supervises its children.
            process.send_signal(signal.SIGINT)
            remaining, _ = process.communicate()
            log.write(remaining)
            sys.stdout.buffer.write(remaining)
            code = process.returncode or 130
    return code, time.perf_counter() - begun


def main():
    """Inspect the local checkout, run its full suite, and save truthful diagnostics."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--inspect-only", action="store_true", help="Read guarded source provenance without launching any suite")
    parser.add_argument("--output-dir", type=Path, help="New output directory outside the checkout")
    args = parser.parse_args()
    repo = args.repo.expanduser().resolve()
    for name in ("ruby", "bundle"):
        if not shutil.which(name):
            raise ValueError("required existing executable unavailable: " + name)
    for key in ("ACT_COVERAGE_CONTEXT", "ACT_SUITE_SELECTION", "ACT_ORDINARY_SUITE", "ACT_PROFILE_OUTPUT", "ACT_PROFILE_INSIDE_CASE"):
        if os.environ.get(key):
            raise ValueError("run outside an existing test/profile child: " + key + " is set")
    expected = inventory(repo)
    for path in ("test/feedback.rb", "test/feedback_coverage.rb", "test/suite_runner.rb", "test/suite_reporter.rb"):
        if not (repo / path).is_file():
            raise ValueError("required ACT harness unavailable: " + path)
    before = fingerprint(repo)
    if args.inspect_only:
        print(json.dumps(before, indent=2))
        return 0
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    if args.output_dir:
        output = args.output_dir.expanduser().resolve()
        if output.is_relative_to(repo):
            raise ValueError("output directory must be outside the repository")
        output.mkdir(mode=0o700, parents=False, exist_ok=False)
    else:
        destination = Path.home() / "Downloads"
        destination.mkdir(exist_ok=True)
        output = Path(tempfile.mkdtemp(prefix="ACT-test-profile-" + stamp + "-", dir=destination)).resolve()
        if output.is_relative_to(repo):
            raise ValueError("run from the ACT checkout, not Downloads; output must be external")
    save_json(output / "before.json", before)
    code, elapsed = run_suite(repo, output)
    problems = []
    try:
        rows, contexts, denominator, problems = collect(repo, output, expected)
    except (ValueError, KeyError, OSError) as error:
        problems.append("measurement export: " + str(error))
        rows = [{"file": path, "case": case, "layer": layer, "seconds": None, "coverage": None,
                 "family": family(path, case), "status": "unavailable", "coverage_detail": str(error), "hits": []}
                for (layer, case), path in expected.items()]
        contexts, denominator = [], None
    after = fingerprint(repo)
    save_json(output / "after.json", after)
    if before != after:
        problems.append("HEAD/index/worktree/source changed during the run; inspect before.json and after.json")
    if before["source_sha256"] != after["source_sha256"]:
        for row in rows:
            row["coverage"] = None
            row["coverage_detail"] = "Source changed during run"
    reports = {str(Path(context["directory"]).parent.parent / "report.json") for context in contexts}
    official = read_json(next(iter(reports))) if len(reports) == 1 and Path(next(iter(reports))).is_file() else {}
    if official:
        save_json(output / "official-report.json", official)
    accepted = bool(code == 0 and official.get("accepted") and official.get("complete_offline_gate"))
    observed = sum(row["seconds"] is not None for row in rows)
    incomplete = observed != len(expected) or any(row["status"] != "pass" for row in rows)
    if incomplete:
        problems.append("Some required tests failed, were interrupted, skipped, or did not run")
    if not accepted:
        problems.append("Canonical complete offline acceptance did not pass; see suite.log")
    union = {tuple(hit) for row in rows if row["coverage"] is not None for hit in row["hits"]}
    combined = official.get("coverage", {}).get("combined", {}).get("line", {}).get("percent")
    metadata = [
        ("Started (UTC)", stamp), ("Repository", str(repo)), ("HEAD", before["head"]),
        ("Working-tree state at start", before["status"]),
        ("Command", "BUNDLE_FROZEN=true bundle exec rake test:all"), ("Runner exit status", code),
        ("Full gate", "PASS" if accepted else "NOT PASSED"),
        ("Observed / expected tests", f"{observed} / {len(expected)}"),
        ("Total suite elapsed (seconds)", elapsed),
        ("Sum of observed test seconds", sum(row["seconds"] or 0 for row in rows)),
        ("Executable production lines", denominator),
        ("Official whole-suite line coverage (%)", combined),
        ("Lines attributed to test execution", len(union)),
        ("Measurement", "Minitest test seconds include setup and teardown. File seconds sum individual test times."),
        ("Coverage denominator", "Every executable line in lib/**/*.rb and bin/agent-coding-tool, including unloaded files."),
        ("Coverage attribution", "Parent counter increases during each test, unioned with verified child-process hits."),
        ("Coverage overlap", "Rows overlap. Percentages are not additive and do not measure unique/marginal contribution."),
        ("Shared startup", "Production loading before test boundaries contributes to whole-suite coverage, not individual rows."),
        ("Wrapper migration", "No Git provenance commands; Ruby source/metadata hashes. Wrapper/preload conditions changed; relative acceptance requires TST-45 review."),
        ("Timing comparability", "Profiling overhead is present. Do not compare total elapsed directly with an unprofiled budget."),
        ("Category assignment", "Reviewed filename/test-purpose mapping; multiple codes indicate cross-cutting tests. UNMAPPED needs review."),
        ("Validation infrastructure", "Feedback-verifier and ordinary-boundary tests are assigned VALD as supporting test infrastructure."),
        ("Source unchanged", before == after),
        ("Measurement issues", "\n".join(problems) or "none"),
    ]
    save_json(output / "measurements.json", {"metadata": metadata, "tests": rows})
    workbook = output / "ACT-test-profile.xlsx"
    write_workbook(workbook, rows, metadata, denominator)
    print("\nXLSX: " + str(workbook), flush=True)
    print(f"Observed {observed}/{len(expected)} tests. Full gate: {'PASS' if accepted else 'NOT PASSED'}.")
    for problem in problems:
        print("NOTE: " + problem, file=sys.stderr)
    return code if code > 0 else 128 - code if code < 0 else 1 if problems else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print("STOP: " + str(error), file=sys.stderr)
        sys.exit(1)

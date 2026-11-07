#!/usr/bin/env python3
"""Fresh production CLI observer; fixtures are generated outside command timing.

Run ROOT OUT [N] [SAMPLES] [LATENCY] [COMPONENT_ROOT]. OUT must be new. All
samples and exact binary streams are retained. Git alone is modeled in the
declared preload; this cannot establish live-host acceptance. No Git executes.
"""
import hashlib
import json
import math
import os
import resource
from pathlib import Path
import signal
import subprocess
import sys
import time


def capture(argv, env, timeout=120):
    """Return elapsed monotonic seconds, exact byte streams and real status.

    Spawn/timeout exceptions propagate; unsuccessful children remain failures.
    """
    started = time.monotonic()
    result = subprocess.run(argv, env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=timeout)
    return time.monotonic() - started, result


def qualify(env):
    """Verify elapsed waits, text/binary streams, nonzero/signal and ENOENT."""
    elapsed, result = capture(["ruby", "-e", 'sleep 0.05; puts "text"; warn "error"'], env)
    assert elapsed >= .05 and result.stdout == b"text\n" and result.stderr == b"error\n" and result.returncode == 0
    _, result = capture(["ruby", "-e", 'STDOUT.write([0,255,128].pack("C*")); STDERR.write([254,0].pack("C*")); exit 7'], env)
    assert result.stdout == bytes([0, 255, 128]) and result.stderr == bytes([254, 0]) and result.returncode == 7
    _, result = capture(["ruby", "-e", 'Process.kill("TERM", Process.pid)'], env)
    assert result.returncode == -signal.SIGTERM
    try:
        capture(["/nonexistent-act-stat-observer"], env)
    except FileNotFoundError:
        return {"status": "PASS", "known_wait_elapsed": elapsed}
    raise AssertionError("missing child did not raise")


def main():
    """Generate the frozen scale curve and retain every warmup/sample outcome."""
    root, output = map(lambda value: Path(value).resolve(), sys.argv[1:3])
    size = int(sys.argv[3]) if len(sys.argv) > 3 else 292
    samples = int(sys.argv[4]) if len(sys.argv) > 4 else 20
    latency = sys.argv[5] if len(sys.argv) > 5 else "0.55"
    output.mkdir()
    env = dict(os.environ)
    env.update(ACT_IMPLEMENTATION="legacy", NO_COLOR="1", COLUMNS="120")
    env.pop("ACT_RESOLVED_COMPOSITION", None)
    if len(sys.argv) > 6:
        env.update(ACT_IMPLEMENTATION="split", ACT_COMPONENT_ROOT=sys.argv[6])
    warmups = int(env.get("ACT_STAT_WARMUPS", "2"))
    report = {"observer": qualify(env), "source_root": str(root), "N": size,
              "source_hashes": {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
                                for path in sorted((root / "lib").rglob("*.rb"))},
              "samples": samples, "warmups": warmups, "latency": float(latency),
              "sink": "PIPE; drained through process exit; raw bytes retained",
              "runtime": subprocess.check_output(["ruby", "-v"], env=env).decode(),
              "platform": os.uname()._asdict() if hasattr(os.uname(), "_asdict") else list(os.uname()),
              "scenarios": []}
    for scale in map(int, env.get("ACT_STAT_SCALES", "1,2,5,10").split(",")):
        scenario = output / str(scale)
        scenario.mkdir()
        data = scenario / "data"
        generated = subprocess.run(["ruby", str(root / "test/support/status_scale.rb"), str(data), str(size * scale)], env=env, capture_output=True, check=True)
        (scenario / "data-hashes.json").write_bytes(generated.stdout)
        child_env = dict(env, AGENT_CODING_TOOL_DATA_DIR=str(data),
                         ACT_STAT_LATENCY=latency,
                         RUBYOPT="-r" + str(root / "test/support/status_scale_probe.rb"))
        rows = []
        for sample in range(-warmups, samples):
            count_path = scenario / f"{sample}.counts.json"
            child_env["ACT_STAT_COUNTS"] = str(count_path)
            before_cpu = resource.getrusage(resource.RUSAGE_CHILDREN)
            elapsed, result = capture(["ruby", str(root / "bin/agent-coding-tool"), "status", "--full"], child_env, timeout=600)
            after_cpu = resource.getrusage(resource.RUSAGE_CHILDREN)
            (scenario / f"{sample}.stdout").write_bytes(result.stdout)
            (scenario / f"{sample}.stderr").write_bytes(result.stderr)
            row = {"sample": sample, "seconds": elapsed, "exit": result.returncode,
                   "user_seconds": after_cpu.ru_utime - before_cpu.ru_utime,
                   "system_seconds": after_cpu.ru_stime - before_cpu.ru_stime,
                   "stdout_sha256": hashlib.sha256(result.stdout).hexdigest(),
                   "counts": json.loads(count_path.read_bytes())}
            rows.append(row)
            (scenario / "samples.json").write_text(json.dumps(rows, indent=2) + "\n")
            if result.returncode:
                raise RuntimeError(f"command failed: {scenario}/{sample}.stderr")
        times = sorted(row["seconds"] for row in rows if row["sample"] >= 0)
        summary = {"tasks": size * scale, "rows": rows,
                   "median": (times[(len(times)-1)//2] + times[len(times)//2]) / 2,
                   "p95": times[math.ceil(.95 * len(times))-1], "max": times[-1]}
        summary["work_budget_pass"] = all(
            row["counts"].get("yaml_tasks") == size * scale
            and row["counts"].get("state_loads") <= size * scale
            and row["counts"].get("authority_probes") <= 7
            and row["counts"].get("remote_refs") == 7
            and 1 <= row["counts"].get("peak_remote_concurrency", 0) <= 8
            for row in rows)
        summary["timing_pass"] = scale not in [1, 10] or summary["p95"] < 1.0
        report["scenarios"].append(summary)
        (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps({key: value for key, value in summary.items() if key != "rows"}), flush=True)
    if not all(row["work_budget_pass"] and row["timing_pass"] for row in report["scenarios"]):
        raise SystemExit(1)


if __name__ == "__main__":
    main()

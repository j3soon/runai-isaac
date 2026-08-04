#!/usr/bin/env python3
"""Verify Isaac Lab 2.2.0, 2.3.2, or 3.0.0-beta2.patch1 L40 KPI files."""

from __future__ import annotations

import argparse
import json
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path


TARGETS = {
    ("single-node-4gpu", "Isaac-Cartpole-Direct-v0"): (2_700_000, 2_100_000, 950_000),
    ("single-node-4gpu", "Isaac-Cartpole-RGB-Camera-Direct-v0"): (130_000, 120_000, 90_000),
    ("single-node-4gpu", "Isaac-Velocity-Rough-G1-v0"): (290_000, 270_000, 250_000),
    ("single-node-4gpu", "Isaac-Repose-Cube-Shadow-Direct-v0"): (440_000, 420_000, 390_000),
    ("multi-node-16gpu", "Isaac-Cartpole-Direct-v0"): (10_200_000, 8_200_000, 3_500_000),
    ("multi-node-16gpu", "Isaac-Cartpole-RGB-Camera-Direct-v0"): (530_000, 490_000, 260_000),
    ("multi-node-16gpu", "Isaac-Velocity-Rough-G1-v0"): (1_200_000, 1_100_000, 960_000),
    ("multi-node-16gpu", "Isaac-Repose-Cube-Shadow-Direct-v0"): (2_400_000, 2_300_000, 1_800_000),
}

EXPECTED_ENVS = {
    "Isaac-Cartpole-Direct-v0": 4096,
    "Isaac-Cartpole-RGB-Camera-Direct-v0": 1024,
    "Isaac-Velocity-Rough-G1-v0": 4096,
    "Isaac-Repose-Cube-Shadow-Direct-v0": 8192,
}

METRICS = ("step", "inference", "train")
TOPOLOGIES = {"single-node-4gpu", "multi-node-16gpu"}


def parse_kpi(path: Path):
    data = json.loads(path.read_text())
    topology = next((part for part in path.parts if part in TOPOLOGIES), None)
    repetition = next(
        (int(match.group(1)) for part in path.parts if (match := re.fullmatch(r"r([123])", part))), None
    )
    if topology is None or repetition is None:
        return None

    benchmark_info = data.get("benchmark_info", {})
    runtime = data.get("runtime", {})
    sim_runtime = data.get("sim_runtime", {})
    task = runtime.get("task") or sim_runtime.get("task") or benchmark_info.get("task")
    num_envs = (
        runtime.get("num_envs") or sim_runtime.get("num_envs") or benchmark_info.get("num_envs")
    )

    gpu_names = []
    gpu_devices = data.get("hardware_info", {}).get("gpu_devices", {})
    if isinstance(gpu_devices, dict):
        gpu_names = [device.get("name") for device in gpu_devices.values() if isinstance(device, dict)]
    if not gpu_names and sim_runtime.get("gpu_device_name"):
        gpu_names = [sim_runtime["gpu_device_name"]]
    if task not in EXPECTED_ENVS:
        raise ValueError(f"unexpected task metadata in {path}: {task}")
    if num_envs != EXPECTED_ENVS[task]:
        raise ValueError(f"unexpected num_envs in {path}: {num_envs}")
    if not gpu_names or any(gpu != "NVIDIA L40" for gpu in gpu_names):
        raise ValueError(f"unexpected GPU inventory in {path}: {gpu_names}")

    workflow = runtime.get("workflow_name") or benchmark_info.get("workflow_name", "")
    max_iterations = runtime.get("max_iterations") or benchmark_info.get("max_iterations")
    num_frames = runtime.get("num_frames") or benchmark_info.get("num_frames")
    if workflow == "benchmark_rlgames_train":
        if max_iterations != 10:
            raise ValueError(f"unexpected max_iterations in {path}")
        values = {
            "step": runtime.get("Mean Environment only FPS"),
            "inference": runtime.get("Mean Environment + Inference FPS"),
            "train": runtime.get("Mean Environment + Inference + Policy update FPS"),
        }
    elif workflow == "benchmark_rsl_rl_train":
        if max_iterations != 10:
            raise ValueError(f"unexpected max_iterations in {path}")
        values = {
            "inference": runtime.get("Mean Collection FPS"),
            "train": runtime.get("Mean Total FPS"),
        }
    elif workflow == "benchmark_non_rl":
        if num_frames != 100:
            raise ValueError(f"unexpected num_frames in {path}")
        values = {"step": runtime.get("Mean Environment step effective FPS")}
    else:
        raise ValueError(f"unexpected workflow in {path}: {workflow}")

    return topology, task, repetition, {
        metric: value for metric, value in values.items() if isinstance(value, (int, float))
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path, help="benchmark artifact root")
    parser.add_argument("--minimum-ratio", type=float, default=0.90)
    parser.add_argument("--maximum-cv", type=float, default=0.05)
    args = parser.parse_args()

    collected = defaultdict(dict)
    errors = []
    paths = set(args.root.rglob("kpis_*.json")) | set(args.root.rglob("benchmark_*.json"))
    for path in sorted(paths):
        try:
            record = parse_kpi(path)
        except (OSError, json.JSONDecodeError, ValueError) as exc:
            errors.append(f"{path}: {exc}")
            continue
        if record is None:
            continue
        topology, task, repetition, values = record
        for metric, value in values.items():
            key = (topology, task, metric)
            if repetition in collected[key]:
                errors.append(f"duplicate {topology}/{task}/{metric}/r{repetition}")
            collected[key][repetition] = value

    outcome = 0
    print("status topology metric median/target CV task")
    for (topology, task), targets in TARGETS.items():
        for metric, target in zip(METRICS, targets):
            by_repetition = collected[(topology, task, metric)]
            values = [by_repetition[index] for index in (1, 2, 3) if index in by_repetition]
            if len(values) != 3:
                print(f"INCOMPLETE   {topology:<18} {metric:<9} {len(values)}/3 runs{'':<23} {task}")
                outcome = max(outcome, 2)
                continue

            median = statistics.median(values)
            mean = statistics.mean(values)
            cv = statistics.pstdev(values) / mean if mean else float("inf")
            ratio = median / target
            if cv > args.maximum_cv:
                status = "INCONCLUSIVE"
                outcome = max(outcome, 2)
            elif ratio < args.minimum_ratio:
                status = "FAIL"
                outcome = max(outcome, 1)
            elif ratio > 1.20:
                status = "PASS_AUDIT"
            else:
                status = "PASS"
            detail = f"{median:.0f}/{target} ({ratio:.1%}) {cv:.2%}"
            print(f"{status:<12} {topology:<18} {metric:<9} {detail:<31} {task}")

    for error in errors:
        print(f"ERROR: {error}", file=sys.stderr)
    if errors:
        return 2
    return outcome


if __name__ == "__main__":
    raise SystemExit(main())

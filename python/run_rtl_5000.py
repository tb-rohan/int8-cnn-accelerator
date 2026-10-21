import argparse
import csv
import json
import os
import subprocess
import time
from pathlib import Path

import numpy as np
import torch
from torchvision import datasets, transforms

from golden import pack_biases, pack_feature_map
from quantized_model import build_quantized_parameters, checkpoint_digest, run_integer_batch
from train import MnistCnn


ROOT = Path(__file__).resolve().parents[1]
CSV_FIELDS = [
    "image_index",
    "label",
    "python_class",
    "rtl_class",
    "expected_hex",
    "rtl_hex",
    "mismatched_bytes",
    "accelerator_cycles",
    "status",
]
TARGET_IMAGES = 5000


def write_words(path, words, width):
    with path.open("w", encoding="ascii", newline="\n") as stream:
        for word in words:
            stream.write(f"{int(word) & ((1 << width) - 1):0{width // 4}x}\n")


def write_batch_files(work_dir, images, labels, parameters):
    result = run_integer_batch(images, parameters)
    write_words(work_dir / "inputs.hex", (word for image in result["input"] for word in pack_feature_map(image)), 32)
    write_words(work_dir / "golden.hex", (int(value) & 0xff for scores in result["scores"] for value in scores), 8)
    with (work_dir / "labels.txt").open("w", encoding="ascii", newline="\n") as stream:
        for label in labels:
            stream.write(f"{int(label)}\n")
    return result


def verify_invariant_vectors(parameters):
    vector_dir = ROOT / "vectors" / "smoke"
    expected = {
        "weights.hex": parameters["weight_words"],
        "biases.hex": pack_biases(np.concatenate(parameters["biases"])),
        "instructions.hex": parameters["instructions"],
    }
    for name, values in expected.items():
        recorded = [int(line, 16) for line in (vector_dir / name).read_text(encoding="ascii").splitlines()]
        if recorded != [int(value) for value in values]:
            raise RuntimeError(f"{vector_dir / name} does not match the fixed checkpoint/calibration export")


def load_parameters(args):
    calibration_path = ROOT / args.calibration_file
    checkpoint_path = ROOT / args.checkpoint
    calibration = json.loads(calibration_path.read_text(encoding="ascii"))
    if calibration.get("checkpoint_sha256") != checkpoint_digest(checkpoint_path):
        raise RuntimeError("fixed calibration manifest does not match the trained checkpoint")
    torch.set_num_threads(args.threads)
    model = MnistCnn()
    model.load_state_dict(torch.load(checkpoint_path, map_location="cpu", weights_only=True))
    model.eval()
    parameters = build_quantized_parameters(model, calibration)
    verify_invariant_vectors(parameters)
    return parameters


def checkpoint_files(checkpoint_dir):
    return sorted(checkpoint_dir.glob("batch_*.json"))


def completed_batches(checkpoint_dir, batch_size):
    completed = []
    next_index = 0
    for path in checkpoint_files(checkpoint_dir):
        checkpoint = json.loads(path.read_text(encoding="ascii"))
        if checkpoint.get("first_image_index") != next_index:
            raise RuntimeError(f"noncontiguous batch checkpoint: {path}")
        if checkpoint.get("images_attempted") != checkpoint.get("last_image_index") - next_index + 1:
            raise RuntimeError(f"inconsistent batch checkpoint: {path}")
        if checkpoint["images_attempted"] > batch_size:
            raise RuntimeError(f"checkpoint batch size exceeds requested batch size: {path}")
        rows_path = checkpoint_dir / checkpoint["results_file"]
        with rows_path.open("r", encoding="ascii", newline="") as stream:
            rows = list(csv.DictReader(stream))
        if len(rows) != checkpoint["images_attempted"]:
            raise RuntimeError(f"checkpoint result row count does not match: {rows_path}")
        completed.append((checkpoint, rows_path, rows))
        next_index = checkpoint["last_image_index"] + 1
    return completed, next_index


def write_aggregate(results_path, batches, failure_rows=()):
    temporary = results_path.with_suffix(".csv.tmp")
    with temporary.open("w", encoding="ascii", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=CSV_FIELDS)
        writer.writeheader()
        for _, _, rows in batches:
            writer.writerows(rows)
        writer.writerows(failure_rows)
    os.replace(temporary, results_path)


def read_rows(path):
    if not path.exists() or path.stat().st_size == 0:
        return []
    with path.open("r", encoding="ascii", newline="") as stream:
        return list(csv.DictReader(stream))


def save_rows(path, rows):
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", encoding="ascii", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=CSV_FIELDS)
        writer.writeheader()
        writer.writerows(rows)
    os.replace(temporary, path)


def merge_progress_rows(first, count, progress_rows, attempt_rows):
    rows = list(progress_rows)
    for row in attempt_rows:
        expected_index = first + len(rows)
        if int(row["image_index"]) != expected_index:
            if int(row["image_index"]) < expected_index:
                continue
            raise RuntimeError(f"noncontiguous in-progress results: expected image {expected_index}, got {row['image_index']}")
        if len(rows) >= count:
            raise RuntimeError("in-progress results exceed their batch range")
        rows.append(row)
    for offset, row in enumerate(rows):
        if int(row["image_index"]) != first + offset:
            raise RuntimeError("in-progress results are not contiguous from the batch start")
    return rows


def summarize(rows, runtime_seconds, status):
    total = len(rows)
    passed = sum(row["status"] == "PASS" for row in rows)
    failed = total - passed
    mismatches = sum(int(row["mismatched_bytes"]) for row in rows)
    cycles = sum(int(row["accelerator_cycles"]) for row in rows)
    python_correct = sum(int(row["python_class"]) == int(row["label"]) for row in rows)
    rtl_correct = sum(int(row["rtl_class"]) == int(row["label"]) for row in rows)
    return {
        "target_images": TARGET_IMAGES,
        "total_images": total,
        "passed_images": passed,
        "failed_images": failed,
        "total_mismatched_bytes": mismatches,
        "total_accelerator_cycles": cycles,
        "cycles_per_image": cycles / total if total else 0,
        "RTL_accuracy": rtl_correct / total if total else 0,
        "Python_INT8_accuracy": python_correct / total if total else 0,
        "wall_clock_runtime": runtime_seconds,
        "regression_status": status,
    }


def save_summary(path, rows, runtime_seconds, status):
    path.write_text(json.dumps(summarize(rows, runtime_seconds, status), indent=2), encoding="ascii")


def build_simulator(args, build_dir, log_path):
    sources = [
        "rtl/cnn_pkg.sv",
        "rtl/pe.sv",
        "rtl/pe_array.sv",
        "rtl/post_proc.sv",
        "rtl/mem_ctrl.sv",
        "rtl/ctrl_unit.sv",
        "rtl/accel_top.sv",
        "tb/tb_top.sv",
    ]
    source_paths = [ROOT / source for source in sources]
    build_dir.mkdir(parents=True, exist_ok=True)
    if args.backend == "iverilog":
        exe_path = build_dir / "tb_top_batch.vvp"
        if exe_path.exists() and exe_path.stat().st_mtime >= max(path.stat().st_mtime for path in source_paths):
            return exe_path, 0.0
        command = [args.iverilog, "-g2012", "-s", "tb_top", "-o", str(exe_path), *sources]
        started = time.perf_counter()
        completed = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, errors="replace", timeout=args.build_timeout)
        elapsed = time.perf_counter() - started
        log_path.write_text(completed.stdout + completed.stderr, encoding="utf-8")
        if completed.returncode != 0 or not exe_path.exists():
            raise RuntimeError(f"Icarus build failed; see {log_path}")
        return exe_path, elapsed

    exe_path = build_dir / "Vtb_top.exe"
    env = os.environ.copy()
    msys = Path(args.msys_root)
    env["PATH"] = os.pathsep.join([str(msys / "ucrt64" / "bin"), str(msys / "usr" / "bin"), env.get("PATH", "")])
    temp_dir = build_dir / "tmp"
    temp_dir.mkdir(parents=True, exist_ok=True)
    root_posix = f"/{ROOT.drive[0].lower()}{ROOT.as_posix()[2:]}"
    build_posix = f"/{build_dir.drive[0].lower()}{build_dir.as_posix()[2:]}"
    temp_posix = f"/{temp_dir.drive[0].lower()}{temp_dir.as_posix()[2:]}"
    setup = "; ".join([
        "export PATH=/ucrt64/bin:$PATH",
        f"export TMP={temp_posix}",
        f"export TEMP={temp_posix}",
        f"export TMPDIR={temp_posix}",
        f"cd {root_posix}",
    ])
    command_line = setup + "; " + " ".join([
        "verilator --binary --timing -O3 -Wno-fatal",
        f"-j {args.build_jobs}",
        "--top-module tb_top",
        f"--Mdir {build_posix}",
        *sources,
    ])
    command = [str(msys / "usr" / "bin" / "bash.exe"), "-lc", command_line]
    started = time.perf_counter()
    completed = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, text=True, errors="replace", timeout=args.build_timeout)
    elapsed = time.perf_counter() - started
    log_path.write_text(completed.stdout + completed.stderr, encoding="utf-8")
    if completed.returncode != 0 or not exe_path.exists():
        raise RuntimeError(f"Verilator build failed; see {log_path}")
    return exe_path, elapsed


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", default="artifacts/mnist_cnn.pt")
    parser.add_argument("--calibration-file", default="artifacts/mnist_int8_calibration.json")
    parser.add_argument("--data", default="data")
    parser.add_argument("--output", default="artifacts/rtl_5000")
    parser.add_argument("--batch-size", type=int, default=100)
    parser.add_argument("--max-batches", type=int)
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--build-jobs", type=int, default=4)
    parser.add_argument("--build-timeout", type=int, default=600)
    parser.add_argument("--batch-timeout", type=int, default=1800)
    parser.add_argument("--backend", choices=("iverilog", "verilator"), default="iverilog")
    parser.add_argument("--iverilog", default="iverilog")
    parser.add_argument("--vvp", default="vvp")
    parser.add_argument("--msys-root", default=r"C:\msys64")
    args = parser.parse_args()
    if args.batch_size < 1 or args.batch_size > 100:
        parser.error("batch size must be between 1 and 100")
    if args.max_batches is not None and args.max_batches < 1:
        parser.error("max batches must be positive")

    output = ROOT / args.output
    checkpoints = output / "checkpoints"
    logs = output / "logs"
    work = output / "work"
    checkpoints.mkdir(parents=True, exist_ok=True)
    logs.mkdir(parents=True, exist_ok=True)
    work.mkdir(parents=True, exist_ok=True)
    results_path = output / "results.csv"
    summary_path = output / "summary.json"
    failures_path = output / "failures.txt"
    failures_path.touch(exist_ok=True)

    batches, next_index = completed_batches(checkpoints, args.batch_size)
    if next_index > TARGET_IMAGES:
        raise RuntimeError(f"checkpoint index exceeds the {TARGET_IMAGES}-image RTL target")
    rows = [row for _, _, batch_rows in batches for row in batch_rows]
    aggregate_runtime = float(batches[-1][0]["cumulative_runtime_seconds"]) if batches else 0.0
    pending_first = next_index
    pending_last = min(TARGET_IMAGES - 1, pending_first + args.batch_size - 1)
    pending_count = pending_last - pending_first + 1 if pending_first < TARGET_IMAGES else 0
    pending_path = checkpoints / f"progress_{pending_first:05d}_{pending_last:05d}.csv"
    pending_rows = merge_progress_rows(pending_first, pending_count, read_rows(pending_path), read_rows(work / "batch_results.csv")) if pending_count else []
    if pending_rows:
        save_rows(pending_path, pending_rows)
    pending_failures = [row for row in pending_rows if int(row["mismatched_bytes"]) != 0 or row["status"] != "PASS"]
    if pending_failures:
        with failures_path.open("a", encoding="utf-8") as stream:
            for row in pending_failures:
                stream.write(json.dumps(row) + "\n")
        write_aggregate(results_path, batches, pending_rows)
        save_summary(summary_path, rows + pending_rows, aggregate_runtime, "FAILED")
        raise RuntimeError(f"bit mismatch at image {pending_failures[0]['image_index']}; regression stopped, see {failures_path}")
    write_aggregate(results_path, batches, pending_rows)
    if next_index == TARGET_IMAGES:
        save_summary(summary_path, rows, aggregate_runtime, "PASS" if all(row["status"] == "PASS" for row in rows) else "FAILED")
        print(f"already_complete images={len(rows)} results={results_path}")
        return

    parameters = load_parameters(args)
    test_data = datasets.MNIST(str(ROOT / args.data), train=False, download=False, transform=transforms.ToTensor())
    build_dir = ROOT / "build" / f"{args.backend}_rtl_5000"
    build_started = time.perf_counter()
    exe_path, build_seconds = build_simulator(args, build_dir, logs / f"{args.backend}_build.log")
    session_started = build_started
    runtime_base = aggregate_runtime
    completed_now = 0
    while next_index < TARGET_IMAGES and (args.max_batches is None or completed_now < args.max_batches):
        first = next_index
        count = min(args.batch_size, TARGET_IMAGES - first)
        last = first + count - 1
        progress_path = checkpoints / f"progress_{first:05d}_{last:05d}.csv"
        progress_rows = merge_progress_rows(first, count, read_rows(progress_path), read_rows(work / "batch_results.csv"))
        if progress_rows:
            save_rows(progress_path, progress_rows)
        if len(progress_rows) == count:
            batch_rows = progress_rows
            sim_seconds = 0.0
            batch_seconds = 0.0
        else:
            launch_first = first + len(progress_rows)
            launch_count = count - len(progress_rows)
            launch_last = last
            batch_started = time.perf_counter()
            images = np.stack([test_data[index][0][0].numpy() for index in range(launch_first, launch_last + 1)])
            labels = [int(test_data[index][1]) for index in range(launch_first, launch_last + 1)]
            write_batch_files(work, images, labels, parameters)
            output_part = work / "batch_results.csv"
            run_name = f"batch_{first:05d}_{last:05d}_from_{launch_first:05d}"
            attempt_log = logs / f"{run_name}_attempt_{time.time_ns()}.log"
            command = [
                args.vvp if args.backend == "iverilog" else str(exe_path),
                *([str(exe_path)] if args.backend == "iverilog" else []),
                "+BATCH_MODE",
                f"+START_INDEX={launch_first}",
                f"+IMAGE_COUNT={launch_count}",
                f"+INPUT_FILE={work.as_posix()}/inputs.hex",
                f"+GOLDEN_FILE={work.as_posix()}/golden.hex",
                f"+LABEL_FILE={work.as_posix()}/labels.txt",
                f"+RESULT_FILE={output_part.as_posix()}",
            ]
            run_started = time.perf_counter()
            try:
                simulation = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, errors="replace", timeout=args.batch_timeout)
            except subprocess.TimeoutExpired as error:
                attempt_log.write_text(str(error.stdout or "") + str(error.stderr or ""), encoding="utf-8")
                attempt_rows = read_rows(output_part)
                progress_rows = merge_progress_rows(first, count, progress_rows, attempt_rows)
                if progress_rows:
                    save_rows(progress_path, progress_rows)
                    write_aggregate(results_path, batches, progress_rows)
                cumulative_runtime = runtime_base + time.perf_counter() - session_started
                save_summary(summary_path, rows + progress_rows, cumulative_runtime, "INCOMPLETE")
                raise RuntimeError(f"batch {first}-{last} exceeded {args.batch_timeout}s after {len(progress_rows)} durable rows; resume will continue at the next image") from error
            sim_seconds = time.perf_counter() - run_started
            attempt_log.write_text(simulation.stdout + simulation.stderr, encoding="utf-8")
            if not output_part.exists():
                save_summary(summary_path, rows + progress_rows, runtime_base + time.perf_counter() - session_started, "INCOMPLETE")
                raise RuntimeError(f"batch {first}-{last} produced no results; see {attempt_log}")
            attempt_rows = read_rows(output_part)
            progress_rows = merge_progress_rows(first, count, progress_rows, attempt_rows)
            if progress_rows:
                save_rows(progress_path, progress_rows)
            mismatch_rows = [row for row in progress_rows if int(row["mismatched_bytes"]) != 0 or row["status"] != "PASS"]
            if mismatch_rows:
                failure_csv = logs / f"{run_name}_failure.csv"
                save_rows(failure_csv, progress_rows)
                with failures_path.open("a", encoding="utf-8") as stream:
                    for row in mismatch_rows:
                        stream.write(json.dumps(row) + "\n")
                write_aggregate(results_path, batches, progress_rows)
                save_summary(summary_path, rows + progress_rows, runtime_base + time.perf_counter() - session_started, "FAILED")
                raise RuntimeError(f"bit mismatch at image {mismatch_rows[0]['image_index']}; regression stopped, see {failure_csv} and {failures_path}")
            if simulation.returncode != 0:
                write_aggregate(results_path, batches, progress_rows)
                save_summary(summary_path, rows + progress_rows, runtime_base + time.perf_counter() - session_started, "INCOMPLETE")
                raise RuntimeError(f"batch simulator exited {simulation.returncode}; see {attempt_log}")
            if len(progress_rows) != count:
                write_aggregate(results_path, batches, progress_rows)
                save_summary(summary_path, rows + progress_rows, runtime_base + time.perf_counter() - session_started, "INCOMPLETE")
                raise RuntimeError(f"batch {first}-{last} stopped after {len(progress_rows)} rows; resume will continue at image {first + len(progress_rows)}")
            batch_rows = progress_rows
            batch_seconds = time.perf_counter() - batch_started
        mismatch_rows = [row for row in batch_rows if int(row["mismatched_bytes"]) != 0 or row["status"] != "PASS"]
        if mismatch_rows:
            failure_csv = logs / f"batch_{first:05d}_{last:05d}_failure.csv"
            save_rows(failure_csv, batch_rows)
            with failures_path.open("a", encoding="utf-8") as stream:
                for row in mismatch_rows:
                    stream.write(json.dumps(row) + "\n")
            write_aggregate(results_path, batches, batch_rows)
            save_summary(summary_path, rows + batch_rows, runtime_base + time.perf_counter() - session_started, "FAILED")
            raise RuntimeError(f"bit mismatch at image {mismatch_rows[0]['image_index']}; regression stopped, see {failure_csv} and {failures_path}")

        batch_csv_name = f"results_{first:05d}_{last:05d}.csv"
        batch_csv_path = checkpoints / batch_csv_name
        save_rows(batch_csv_path, batch_rows)
        cumulative_runtime = runtime_base + time.perf_counter() - session_started
        checkpoint = {
            "first_image_index": first,
            "last_image_index": last,
            "images_attempted": count,
            "images_passed": count,
            "images_failed": 0,
            "total_mismatched_output_bytes": 0,
            "total_accelerator_clocks": sum(int(row["accelerator_cycles"]) for row in batch_rows),
            "elapsed_runtime_seconds": batch_seconds,
            "cumulative_runtime_seconds": cumulative_runtime,
            "last_completed_image": last,
            "results_file": batch_csv_name,
            "simulator_runtime_seconds": sim_seconds,
            "preparation_runtime_seconds": max(0.0, batch_seconds - sim_seconds),
            "simulator_build_seconds": build_seconds if first == 0 else 0.0,
            "checkpoint_sha256": checkpoint_digest(ROOT / args.checkpoint),
            "calibration_sha256": checkpoint_digest(ROOT / args.calibration_file),
        }
        checkpoint_path = checkpoints / f"batch_{first:05d}_{last:05d}.json"
        checkpoint_temp = checkpoint_path.with_suffix(".json.tmp")
        checkpoint_temp.write_text(json.dumps(checkpoint, indent=2), encoding="ascii")
        os.replace(checkpoint_temp, checkpoint_path)
        batches.append((checkpoint, batch_csv_path, batch_rows))
        rows.extend(batch_rows)
        aggregate_runtime = cumulative_runtime
        next_index = last + 1
        completed_now += 1
        write_aggregate(results_path, batches)
        status = "PASS" if next_index == TARGET_IMAGES else "IN_PROGRESS"
        save_summary(summary_path, rows, aggregate_runtime, status)
        print(f"batch={first}-{last} passed={count} clocks={checkpoint['total_accelerator_clocks']} batch_seconds={batch_seconds:.2f} completed={next_index}/{TARGET_IMAGES}")

    if next_index == TARGET_IMAGES:
        save_summary(summary_path, rows, aggregate_runtime, "PASS")
        print(f"PASS images={TARGET_IMAGES} rtl_accuracy={summarize(rows, aggregate_runtime, 'PASS')['RTL_accuracy']:.6%} runtime_seconds={aggregate_runtime:.2f}")
    else:
        print(f"PAUSED completed={next_index}/{TARGET_IMAGES} results={results_path}")


if __name__ == "__main__":
    main()

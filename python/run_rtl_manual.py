import argparse
import csv
import json
import subprocess
import time
from datetime import datetime
from pathlib import Path
from types import SimpleNamespace

import numpy as np
from PIL import Image
from torchvision import transforms

from golden import write_hex_words
from quantized_model import run_integer_batch
from run_rtl_5000 import build_simulator, load_parameters, write_batch_files


ROOT = Path(__file__).resolve().parents[1]
RTL_SOURCES = [
    "rtl/cnn_pkg.sv",
    "rtl/pe.sv",
    "rtl/pe_array.sv",
    "rtl/post_proc.sv",
    "rtl/mem_ctrl.sv",
    "rtl/ctrl_unit.sv",
    "rtl/accel_top.sv",
    "tb/tb_top.sv",
]


def load_raster(path):
    with Image.open(path) as source:
        image = source.convert("L")
    if image.size != (28, 28):
        raise ValueError(f"raster input must already be 28x28 pixels; got {image.width}x{image.height}")
    return transforms.ToTensor()(image)[0].numpy()


def load_raw(path):
    values = np.load(path, allow_pickle=False)
    if values.shape != (28, 28):
        raise ValueError(f"raw input must have shape 28x28; got {values.shape}")
    if values.dtype.kind not in "biuf" or not np.isfinite(values).all():
        raise ValueError("raw input must contain finite numeric pixel values")
    image = values.astype(np.float32)
    if image.size and (float(image.min()) < 0.0 or float(image.max()) > 255.0):
        raise ValueError("raw input values must be in the range 0..1 or 0..255")
    if image.size and float(image.max()) > 1.0:
        image /= 255.0
    return image


def decode_scores(value):
    if len(value) != 24:
        raise ValueError(f"expected 12 output bytes, got {len(value) // 2}")
    raw = [int(value[offset:offset + 2], 16) for offset in range(0, 24, 2)]
    return [byte - 256 if byte >= 128 else byte for byte in raw[:10]], raw


def safe_name(value):
    cleaned = "".join(char if char.isascii() and (char.isalnum() or char in "._-") else "_" for char in value)
    return cleaned.strip("._") or "image"


def load_result(path):
    with path.open("r", encoding="ascii", newline="") as stream:
        rows = list(csv.DictReader(stream))
    if len(rows) != 1:
        raise RuntimeError(f"expected one RTL result row, found {len(rows)}")
    return rows[0]


def parse_args():
    parser = argparse.ArgumentParser(description="Run one INT8 MNIST-style image through accel_top over AXI/DMA.")
    parser.add_argument("image", nargs="?", help="28x28 PNG, JPG, or JPEG image")
    parser.add_argument("--raw", metavar="NPY", help="28x28 .npy pixels in the range 0..1 or 0..255")
    parser.add_argument("--checkpoint", default="artifacts/mnist_cnn.pt")
    parser.add_argument("--calibration-file", default="artifacts/mnist_int8_calibration.json")
    parser.add_argument("--output-root", default="artifacts/manual")
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--iverilog", default="iverilog")
    parser.add_argument("--vvp", default="vvp")
    parser.add_argument("--build-timeout", type=int, default=600)
    parser.add_argument("--sim-timeout", type=int, default=1800)
    args = parser.parse_args()
    if bool(args.image) == bool(args.raw):
        parser.error("provide exactly one raster image path or --raw input.npy")
    return args


def main():
    args = parse_args()
    input_path = Path(args.raw or args.image).expanduser().resolve()
    if not input_path.is_file():
        raise FileNotFoundError(input_path)
    if args.raw:
        if input_path.suffix.lower() != ".npy":
            raise ValueError("--raw input must be a .npy file")
        image = load_raw(input_path)
        input_mode = "raw_npy"
    else:
        if input_path.suffix.lower() not in (".png", ".jpg", ".jpeg"):
            raise ValueError("raster input must be a PNG, JPG, or JPEG file")
        image = load_raster(input_path)
        input_mode = "grayscale_to_tensor"

    checkpoint = Path(args.checkpoint)
    calibration = Path(args.calibration_file)
    checkpoint = checkpoint if checkpoint.is_absolute() else ROOT / checkpoint
    calibration = calibration if calibration.is_absolute() else ROOT / calibration
    parameters = load_parameters(SimpleNamespace(
        checkpoint=str(checkpoint),
        calibration_file=str(calibration),
        threads=args.threads,
    ))

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
    output_root = Path(args.output_root).expanduser()
    output_root = output_root if output_root.is_absolute() else ROOT / output_root
    run_dir = output_root / f"{timestamp}_{safe_name(input_path.stem)}"
    run_dir.mkdir(parents=True, exist_ok=False)
    np.save(run_dir / "preprocessed_28x28.npy", image.astype(np.float32))
    integer_result = write_batch_files(run_dir, image[None, :, :], [-1], parameters)

    build_dir = output_root / "build"
    build_args = SimpleNamespace(
        backend="iverilog",
        iverilog=args.iverilog,
        build_timeout=args.build_timeout,
    )
    simulator, build_seconds = build_simulator(build_args, build_dir, run_dir / "iverilog_build.log")
    result_path = run_dir / "rtl_result.csv"
    command = [
        args.vvp,
        str(simulator),
        "+BATCH_MODE",
        "+START_INDEX=0",
        "+IMAGE_COUNT=1",
        f"+INPUT_FILE={(run_dir / 'inputs.hex').as_posix()}",
        f"+GOLDEN_FILE={(run_dir / 'golden.hex').as_posix()}",
        f"+LABEL_FILE={(run_dir / 'labels.txt').as_posix()}",
        f"+RESULT_FILE={result_path.as_posix()}",
    ]
    started = time.perf_counter()
    try:
        simulation = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, errors="replace", timeout=args.sim_timeout)
    except subprocess.TimeoutExpired as error:
        stdout = error.stdout.decode(errors="replace") if isinstance(error.stdout, bytes) else (error.stdout or "")
        stderr = error.stderr.decode(errors="replace") if isinstance(error.stderr, bytes) else (error.stderr or "")
        (run_dir / "simulator.log").write_text(stdout + stderr, encoding="utf-8")
        raise TimeoutError(f"single-image RTL simulation exceeded {args.sim_timeout}s; see {run_dir / 'simulator.log'}") from error
    simulation_seconds = time.perf_counter() - started
    (run_dir / "simulator.log").write_text(simulation.stdout + simulation.stderr, encoding="utf-8")
    if simulation.returncode != 0 or not result_path.exists():
        raise RuntimeError(f"RTL simulation failed with exit code {simulation.returncode}; see {run_dir / 'simulator.log'}")

    row = load_result(result_path)
    rtl_scores, rtl_bytes = decode_scores(row["rtl_hex"])
    python_scores = [int(value) for value in integer_result["scores"][0, :10]]
    python_bytes = [int(value) & 0xff for value in integer_result["scores"][0]]
    rtl_prediction = int(np.argmax(rtl_scores))
    python_prediction = int(np.argmax(python_scores))
    mismatch_count = sum(left != right for left, right in zip(rtl_bytes, python_bytes))
    write_hex_words(run_dir / "rtl_result.hex", rtl_bytes, 8)
    result = {
        "input_path": str(input_path),
        "input_mode": input_mode,
        "input_shape": [28, 28],
        "input_scale": parameters["calibration"]["input_scale"],
        "rtl_prediction": rtl_prediction,
        "rtl_class_scores": rtl_scores,
        "python_int8_prediction": python_prediction,
        "python_int8_class_scores": python_scores,
        "rtl_output_bytes": rtl_bytes,
        "python_golden_bytes": python_bytes,
        "mismatched_output_bytes": mismatch_count,
        "accelerator_cycles": int(row["accelerator_cycles"]),
        "rtl_status": row["status"],
        "simulation_runtime_seconds": simulation_seconds,
        "simulator_build_seconds": build_seconds,
    }
    (run_dir / "manual_result.json").write_text(json.dumps(result, indent=2), encoding="ascii")

    print(f"RTL predicted digit: {rtl_prediction}")
    print(f"RTL class scores (0-9): {rtl_scores}")
    print(f"Python INT8 golden prediction: {python_prediction}")
    print(f"Python INT8 class scores (0-9): {python_scores}")
    print(f"RTL/Python output comparison: {'MATCH' if mismatch_count == 0 else 'MISMATCH'} ({12 - mismatch_count}/12 bytes)")
    print(f"Accelerator cycles: {row['accelerator_cycles']}")
    print(f"Debug artifacts: {run_dir}")
    if mismatch_count != 0 or row["status"] != "PASS":
        raise RuntimeError(f"RTL output differs from the Python INT8 golden output; see {run_dir / 'manual_result.json'}")


if __name__ == "__main__":
    main()

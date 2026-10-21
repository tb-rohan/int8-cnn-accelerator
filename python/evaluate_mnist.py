import argparse
import json
from pathlib import Path

import numpy as np
import torch
from torch.utils.data import DataLoader, Subset
from torchvision import datasets, transforms

from quantized_model import build_quantized_parameters, load_or_calibrate, run_integer_batch
from train import MnistCnn


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", default="artifacts/mnist_cnn.pt")
    parser.add_argument("--data", default="data")
    parser.add_argument("--calibration-file", default="artifacts/mnist_int8_calibration.json")
    parser.add_argument("--calibration-count", type=int, default=1024)
    parser.add_argument("--calibration-seed", type=int, default=2027)
    parser.add_argument("--samples", type=int, default=10000)
    parser.add_argument("--batch-size", type=int, default=128)
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--report", default="artifacts/mnist_int8_evaluation.json")
    args = parser.parse_args()
    torch.set_num_threads(args.threads)
    model = MnistCnn()
    model.load_state_dict(torch.load(args.checkpoint, map_location="cpu", weights_only=True))
    model.eval()
    dataset = datasets.MNIST(args.data, train=True, download=True, transform=transforms.ToTensor())
    calibration = load_or_calibrate(model, dataset, args.checkpoint, args.calibration_file, args.calibration_count, args.calibration_seed, args.batch_size)
    parameters = build_quantized_parameters(model, calibration)

    test_data = datasets.MNIST(args.data, train=False, download=True, transform=transforms.ToTensor())
    sample_count = min(args.samples, len(test_data))
    loader = DataLoader(Subset(test_data, range(sample_count)), batch_size=args.batch_size, shuffle=False)
    fp32_correct = 0
    int8_correct = 0
    with torch.no_grad():
        for images, labels in loader:
            padded = torch.cat((images, torch.zeros(images.shape[0], 3, 28, 28)), dim=1)
            fp32_scores, _, _, _, _ = model(padded)
            integer_result = run_integer_batch(images[:, 0].numpy(), parameters)
            fp32_correct += int((fp32_scores.argmax(1) == labels).sum())
            int8_predictions = integer_result["scores"][:, :10].argmax(axis=1)
            int8_correct += int(np.count_nonzero(int8_predictions == labels.numpy()))

    report = {
        "checkpoint": str(Path(args.checkpoint)),
        "test_samples": sample_count,
        "calibration_samples": calibration["sample_count"],
        "calibration_seed": calibration["seed"],
        "input_scale": calibration["input_scale"],
        "activation_scales": calibration["activation_scales"],
        "fp32_correct": fp32_correct,
        "fp32_incorrect": sample_count - fp32_correct,
        "fp32_accuracy": fp32_correct / sample_count,
        "int8_correct": int8_correct,
        "int8_incorrect": sample_count - int8_correct,
        "int8_accuracy": int8_correct / sample_count,
        "layer_quant_mult_shift": parameters["quant_pairs"],
    }
    report_path = Path(args.report)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2), encoding="ascii")
    print(f"samples={sample_count}")
    print(f"fp32_correct={fp32_correct} fp32_incorrect={sample_count - fp32_correct} fp32_accuracy={fp32_correct / sample_count:.6%}")
    print(f"int8_correct={int8_correct} int8_incorrect={sample_count - int8_correct} int8_accuracy={int8_correct / sample_count:.6%}")
    print(f"calibration_samples={calibration['sample_count']} seed={calibration['seed']} scales={calibration['activation_scales']}")
    print(f"quant_mult_shift={parameters['quant_pairs']}")
    print(f"report={report_path}")


if __name__ == "__main__":
    main()

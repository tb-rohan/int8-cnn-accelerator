import argparse
import json
from pathlib import Path

import numpy as np
import torch
from torchvision import datasets, transforms

from golden import pack_feature_map, write_hex_words
from quantized_model import build_quantized_parameters, load_or_calibrate, run_integer_batch
from train import MnistCnn


def load_image(args, dataset):
    if args.image:
        image = np.load(args.image).astype(np.float32)
        if image.shape == (28, 28, 1):
            image = image[:, :, 0]
        if image.shape != (28, 28):
            raise ValueError("image must have shape 28x28 or 28x28x1")
        if image.max() > 1:
            image = image / 255.0
        return image
    return dataset[args.index][0][0].numpy()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", default="artifacts/mnist_cnn.pt")
    parser.add_argument("--data", default="data")
    parser.add_argument("--image")
    parser.add_argument("--index", type=int, default=0)
    parser.add_argument("--output", default="vectors/smoke")
    parser.add_argument("--calibration-file", default="artifacts/mnist_int8_calibration.json")
    parser.add_argument("--calibration-count", type=int, default=1024)
    parser.add_argument("--calibration-seed", type=int, default=2027)
    parser.add_argument("--batch-size", type=int, default=128)
    parser.add_argument("--threads", type=int, default=4)
    args = parser.parse_args()
    torch.set_num_threads(args.threads)
    model = MnistCnn()
    model.load_state_dict(torch.load(args.checkpoint, map_location="cpu", weights_only=True))
    model.eval()
    transform = transforms.ToTensor()
    calibration_data = datasets.MNIST(args.data, train=True, download=True, transform=transform)
    test_data = datasets.MNIST(args.data, train=False, download=True, transform=transform)
    calibration = load_or_calibrate(model, calibration_data, args.checkpoint, args.calibration_file, args.calibration_count, args.calibration_seed, args.batch_size)
    parameters = build_quantized_parameters(model, calibration)
    image = load_image(args, test_data)
    result = run_integer_batch(image[None, :, :], parameters)

    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)
    write_hex_words(output_dir / "weights.hex", parameters["weight_words"], 32)
    write_hex_words(output_dir / "biases.hex", parameters["bias_words"], 128)
    write_hex_words(output_dir / "instructions.hex", parameters["instructions"], 128)
    write_hex_words(output_dir / "input.hex", pack_feature_map(result["input"][0]), 32)
    for index, fmap in enumerate(result["layers"]):
        write_hex_words(output_dir / f"golden_layer{index}.hex", pack_feature_map(fmap[0]), 32)
    with (output_dir / "layer_configs.json").open("w", encoding="ascii") as stream:
        json.dump(parameters["layers"], stream, indent=2)
    with (output_dir / "quantization.json").open("w", encoding="ascii") as stream:
        json.dump(calibration, stream, indent=2)
    prediction = int(np.argmax(result["scores"][0, :10]))
    print(f"prediction={prediction} scores={result['scores'][0, :10].tolist()}")
    print(f"weights_words={len(parameters['weight_words'])} bias_words={len(parameters['bias_words'])} instructions={len(parameters['instructions'])}")
    print(f"calibration_samples={calibration['sample_count']} calibration_seed={calibration['seed']} activation_scales={calibration['activation_scales']}")


if __name__ == "__main__":
    main()

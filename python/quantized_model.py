import hashlib
import json
from pathlib import Path

import numpy as np
import torch
from torch.utils.data import DataLoader, Subset

from golden import conv2d_int8_batch, fully_connected_int8_batch, max_pool2x2_batch, pack_biases, pack_instruction, pack_weights
from quantize import fixed_multiplier, quantize_bias, quantize_tensor


INPUT_SCALE = 1.0 / 127.0


def checkpoint_digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def calibrate_activation_scales(model, dataset, sample_count=1024, seed=2027, batch_size=128):
    if sample_count < 1 or sample_count > len(dataset):
        raise ValueError("calibration sample count must be within the dataset")
    indices = np.random.default_rng(seed).permutation(len(dataset))[:sample_count].tolist()
    loader = DataLoader(Subset(dataset, indices), batch_size=batch_size, shuffle=False)
    peaks = np.zeros(3, dtype=np.float64)
    model.eval()
    with torch.no_grad():
        for images, _ in loader:
            images = torch.cat((images, torch.zeros(images.shape[0], 3, 28, 28)), dim=1)
            scores, first, _, second, _ = model(images)
            for index, value in enumerate((first, second, scores)):
                peaks[index] = max(peaks[index], float(value.abs().max()))
    scales = [max(float(peak / 127.0), 1e-8) for peak in peaks]
    return {
        "input_scale": INPUT_SCALE,
        "activation_scales": scales,
        "sample_count": sample_count,
        "seed": seed,
    }


def load_or_calibrate(model, dataset, checkpoint_path, calibration_path, sample_count=1024, seed=2027, batch_size=128):
    calibration_path = Path(calibration_path)
    digest = checkpoint_digest(checkpoint_path)
    if calibration_path.exists():
        calibration = json.loads(calibration_path.read_text(encoding="ascii"))
        if calibration.get("checkpoint_sha256") == digest and calibration.get("sample_count") == sample_count and calibration.get("seed") == seed:
            return calibration
    calibration = calibrate_activation_scales(model, dataset, sample_count, seed, batch_size)
    calibration["checkpoint_sha256"] = digest
    calibration_path.parent.mkdir(parents=True, exist_ok=True)
    calibration_path.write_text(json.dumps(calibration, indent=2), encoding="ascii")
    return calibration


def build_quantized_parameters(model, calibration):
    activation_scales = calibration["activation_scales"]
    if len(activation_scales) != 3 or any(scale <= 0 for scale in activation_scales):
        raise ValueError("calibration must contain three positive activation scales")
    input_scale = float(calibration["input_scale"])
    weight_words = []
    bias_words = []
    weights = []
    biases = []
    layers = []
    weight_base = 0
    bias_base = 0

    def add_compute(op, shape, kernel, float_weight, float_bias, current_scale, output_scale, relu):
        nonlocal weight_base, bias_base
        qweight, weight_scale = quantize_tensor(float_weight)
        if op == 0:
            qweight = qweight.transpose(2, 3, 1, 0).copy()
        else:
            qweight = qweight.T.reshape(1, 1, float_weight.shape[1], float_weight.shape[0])
        qbias = quantize_bias(float_bias, current_scale * weight_scale)
        multiplier, shift = fixed_multiplier(current_scale * weight_scale / output_scale)
        words = pack_weights(qweight)
        weight_words.extend(words)
        bias_words.extend(pack_biases(qbias))
        weights.append(qweight)
        biases.append(qbias)
        layers.append({
            "op": op,
            "in_h": shape[0],
            "in_w": shape[1],
            "in_c": shape[2],
            "out_c": qweight.shape[3],
            "kernel": kernel,
            "stride": 1,
            "pad": 1 if op == 0 and kernel == 3 else 0,
            "relu_en": int(relu),
            "w_base": weight_base,
            "b_base": bias_base,
            "quant_mult": multiplier,
            "quant_shift": shift,
        })
        weight_base += len(words)
        bias_base += len(qbias) // 4
        return multiplier, shift

    conv1_weight = model.conv1.weight.detach().cpu().numpy()
    conv1_bias = model.conv1.bias.detach().cpu().numpy()
    conv1_quant = add_compute(0, (28, 28, 4), 3, conv1_weight, conv1_bias, input_scale, activation_scales[0], True)
    layers.append({"op": 1, "in_h": 28, "in_w": 28, "in_c": 8, "out_c": 8, "kernel": 2, "stride": 2, "pad": 0, "relu_en": 0, "w_base": 0, "b_base": 0, "quant_mult": 1, "quant_shift": 0})

    conv2_weight = model.conv2.weight.detach().cpu().numpy()
    conv2_bias = model.conv2.bias.detach().cpu().numpy()
    conv2_quant = add_compute(0, (14, 14, 8), 3, conv2_weight, conv2_bias, activation_scales[0], activation_scales[1], True)
    layers.append({"op": 1, "in_h": 14, "in_w": 14, "in_c": 8, "out_c": 8, "kernel": 2, "stride": 2, "pad": 0, "relu_en": 0, "w_base": 0, "b_base": 0, "quant_mult": 1, "quant_shift": 0})

    fc_weight = model.fc.weight.detach().cpu().numpy().reshape(10, 8, 7, 7).transpose(0, 2, 3, 1).reshape(10, 392)
    padded_weight = np.zeros((12, 392), dtype=np.float32)
    padded_weight[:10] = fc_weight
    padded_bias = np.zeros(12, dtype=np.float32)
    padded_bias[:10] = model.fc.bias.detach().cpu().numpy()
    fc_quant = add_compute(2, (1, 1, 392), 1, padded_weight, padded_bias, activation_scales[1], activation_scales[2], False)

    instructions = [pack_instruction(layer) for layer in layers]
    instructions.append(pack_instruction({"op": 3}))
    return {
        "weights": weights,
        "biases": biases,
        "weight_words": weight_words,
        "bias_words": bias_words,
        "layers": layers,
        "instructions": instructions,
        "quant_pairs": [conv1_quant, conv2_quant, fc_quant],
        "calibration": calibration,
    }


def run_integer_batch(images, parameters):
    images = np.asarray(images, dtype=np.float32)
    if images.ndim == 2:
        images = images[None, :, :]
    if images.ndim != 3 or images.shape[1:] != (28, 28):
        raise ValueError("images must have shape batch by 28 by 28")
    input_map = np.zeros((images.shape[0], 28, 28, 4), dtype=np.float32)
    input_map[:, :, :, 0] = images
    qinput = np.clip(np.rint(input_map / parameters["calibration"]["input_scale"]), -128, 127).astype(np.int8)

    conv1 = conv2d_int8_batch(qinput, parameters["weights"][0], parameters["biases"][0], 1, 1, *parameters["quant_pairs"][0], True)
    pool1 = max_pool2x2_batch(conv1)
    conv2 = conv2d_int8_batch(pool1, parameters["weights"][1], parameters["biases"][1], 1, 1, *parameters["quant_pairs"][1], True)
    pool2 = max_pool2x2_batch(conv2)
    fc_values = pool2.reshape(pool2.shape[0], -1)
    fc_weights = parameters["weights"][2].reshape(392, 12)
    scores = fully_connected_int8_batch(fc_values, fc_weights, parameters["biases"][2], *parameters["quant_pairs"][2])
    return {
        "input": qinput,
        "layers": [conv1, pool1, conv2, pool2, scores.reshape(-1, 1, 1, 12)],
        "scores": scores,
    }

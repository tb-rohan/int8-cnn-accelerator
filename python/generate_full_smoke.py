import json
from pathlib import Path

import numpy as np

from golden import conv2d_int8, fully_connected_int8, max_pool2x2, pack_biases, pack_feature_map, pack_instruction, pack_weights, write_hex_words


def main():
    output = Path("vectors/smoke")
    output.mkdir(parents=True, exist_ok=True)
    image = np.zeros((28, 28, 4), dtype=np.int8)
    for y in range(28):
        for x in range(28):
            image[y, x, 0] = (y * 28 + x) % 97
    conv1_weights = np.zeros((3, 3, 4, 8), dtype=np.int8)
    for channel in range(4):
        conv1_weights[1, 1, channel, channel] = 1
    conv2_weights = np.zeros((3, 3, 8, 8), dtype=np.int8)
    for channel in range(8):
        conv2_weights[1, 1, channel, channel] = 1
    fc_weights = np.zeros((1, 1, 392, 12), dtype=np.int8)
    for output_index in range(10):
        fc_weights[0, 0, output_index * 8, output_index] = 1
    conv1_bias = np.zeros(8, dtype=np.int32)
    conv2_bias = np.zeros(8, dtype=np.int32)
    fc_bias = np.zeros(12, dtype=np.int32)
    conv1 = conv2d_int8(image, conv1_weights, conv1_bias, 1, 1, 1, 0, True)
    pool1 = max_pool2x2(conv1)
    conv2 = conv2d_int8(pool1, conv2_weights, conv2_bias, 1, 1, 1, 0, True)
    pool2 = max_pool2x2(conv2)
    fc = fully_connected_int8(pool2, fc_weights.reshape(392, 12), fc_bias, 1, 0).reshape(1, 1, 12)
    configs = [
        {"op": 0, "in_h": 28, "in_w": 28, "in_c": 4, "out_c": 8, "kernel": 3, "stride": 1, "pad": 1, "relu_en": 1, "w_base": 0, "b_base": 0, "quant_mult": 1, "quant_shift": 0},
        {"op": 1, "in_h": 28, "in_w": 28, "in_c": 8, "out_c": 8, "kernel": 2, "stride": 2, "pad": 0, "relu_en": 0, "w_base": 0, "b_base": 0, "quant_mult": 1, "quant_shift": 0},
        {"op": 0, "in_h": 14, "in_w": 14, "in_c": 8, "out_c": 8, "kernel": 3, "stride": 1, "pad": 1, "relu_en": 1, "w_base": 72, "b_base": 2, "quant_mult": 1, "quant_shift": 0},
        {"op": 1, "in_h": 14, "in_w": 14, "in_c": 8, "out_c": 8, "kernel": 2, "stride": 2, "pad": 0, "relu_en": 0, "w_base": 0, "b_base": 0, "quant_mult": 1, "quant_shift": 0},
        {"op": 2, "in_h": 1, "in_w": 1, "in_c": 392, "out_c": 12, "kernel": 1, "stride": 1, "pad": 0, "relu_en": 0, "w_base": 216, "b_base": 4, "quant_mult": 1, "quant_shift": 0},
    ]
    instructions = [pack_instruction(config) for config in configs]
    instructions.append(pack_instruction({"op": 3}))
    packed_weights = pack_weights(conv1_weights) + pack_weights(conv2_weights) + pack_weights(fc_weights)
    packed_biases = pack_biases(conv1_bias) + pack_biases(conv2_bias) + pack_biases(fc_bias)
    write_hex_words(output / "weights.hex", packed_weights, 32)
    write_hex_words(output / "biases.hex", packed_biases, 128)
    write_hex_words(output / "instructions.hex", instructions, 128)
    write_hex_words(output / "input.hex", pack_feature_map(image), 32)
    for index, fmap in enumerate((conv1, pool1, conv2, pool2, fc)):
        write_hex_words(output / f"golden_layer{index}.hex", pack_feature_map(fmap), 32)
    with open(output / "layer_configs.json", "w", encoding="ascii") as stream:
        json.dump(configs, stream, indent=2)
    print(f"golden_scores={fc.reshape(-1)[:10].tolist()}")
    print(f"weights_words={len(packed_weights)} bias_words={len(packed_biases)} input_words={len(pack_feature_map(image))}")


if __name__ == "__main__":
    main()

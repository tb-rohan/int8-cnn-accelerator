import numpy as np


def quantize_tensor(values):
    values = np.asarray(values, dtype=np.float64)
    peak = float(np.max(np.abs(values))) if values.size else 0.0
    scale = peak / 127.0 if peak else 1.0
    quantized = np.clip(np.rint(values / scale), -128, 127).astype(np.int8)
    return quantized, scale


def quantize_bias(values, scale):
    values = np.asarray(values, dtype=np.float64)
    return np.clip(np.rint(values / scale), -(1 << 31), (1 << 31) - 1).astype(np.int32)


def fixed_multiplier(real_scale):
    if real_scale < 0:
        raise ValueError("real scale must be nonnegative")
    if real_scale == 0:
        return 0, 0
    for shift in range(31, -1, -1):
        multiplier = int(np.rint(real_scale * (1 << shift)))
        if 1 <= multiplier <= 65535:
            return multiplier, shift
    return 1, 0


def quantize_activation(values, scale):
    values = np.asarray(values, dtype=np.float64)
    return np.clip(np.rint(values / scale), -128, 127).astype(np.int8)

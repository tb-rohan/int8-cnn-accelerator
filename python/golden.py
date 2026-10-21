import numpy as np


N = 4


def requantize(accumulator, bias, multiplier, shift, relu=False):
    accumulator = np.asarray(accumulator, dtype=np.int64)
    bias = np.asarray(bias, dtype=np.int64)
    value = (accumulator + bias) * int(multiplier)
    if shift:
        value = (value + (1 << (shift - 1))) >> shift
    if relu:
        value = np.maximum(value, 0)
    return np.clip(value, -128, 127).astype(np.int8)


def conv2d_int8(image, weights, bias, stride=1, pad=0, multiplier=1, shift=0, relu=True):
    image = np.asarray(image, dtype=np.int8)
    weights = np.asarray(weights, dtype=np.int8)
    bias = np.asarray(bias, dtype=np.int32)
    height, width, channels = image.shape
    kernel_h, kernel_w, weight_channels, outputs = weights.shape
    if channels != weight_channels:
        raise ValueError("input and weight channel counts differ")
    out_h = (height + 2 * pad - kernel_h) // stride + 1
    out_w = (width + 2 * pad - kernel_w) // stride + 1
    padded = np.pad(image.astype(np.int64), ((pad, pad), (pad, pad), (0, 0)))
    accum = np.zeros((out_h, out_w, outputs), dtype=np.int64)
    for ky in range(kernel_h):
        for kx in range(kernel_w):
            for channel in range(channels):
                patch = padded[ky:ky + out_h * stride:stride, kx:kx + out_w * stride:stride, channel]
                accum += patch[:, :, None] * weights[ky, kx, channel, :].astype(np.int64)[None, None, :]
    return requantize(accum, bias, multiplier, shift, relu)


def conv2d_int8_batch(images, weights, bias, stride=1, pad=0, multiplier=1, shift=0, relu=True):
    images = np.asarray(images, dtype=np.int8)
    weights = np.asarray(weights, dtype=np.int8)
    bias = np.asarray(bias, dtype=np.int32)
    batch, height, width, channels = images.shape
    kernel_h, kernel_w, weight_channels, outputs = weights.shape
    if channels != weight_channels:
        raise ValueError("input and weight channel counts differ")
    out_h = (height + 2 * pad - kernel_h) // stride + 1
    out_w = (width + 2 * pad - kernel_w) // stride + 1
    padded = np.pad(images.astype(np.int64), ((0, 0), (pad, pad), (pad, pad), (0, 0)))
    accum = np.zeros((batch, out_h, out_w, outputs), dtype=np.int64)
    for ky in range(kernel_h):
        for kx in range(kernel_w):
            for channel in range(channels):
                patch = padded[:, ky:ky + out_h * stride:stride, kx:kx + out_w * stride:stride, channel]
                accum += patch[:, :, :, None] * weights[ky, kx, channel, :].astype(np.int64)[None, None, None, :]
    return requantize(accum, bias, multiplier, shift, relu)


def max_pool2x2(image):
    image = np.asarray(image, dtype=np.int8)
    height, width, channels = image.shape
    if height % 2 or width % 2:
        raise ValueError("pool input dimensions must be even")
    return np.maximum.reduce((image[0::2, 0::2], image[0::2, 1::2], image[1::2, 0::2], image[1::2, 1::2])).astype(np.int8)


def max_pool2x2_batch(images):
    images = np.asarray(images, dtype=np.int8)
    _, height, width, _ = images.shape
    if height % 2 or width % 2:
        raise ValueError("pool input dimensions must be even")
    return np.maximum.reduce((images[:, 0::2, 0::2], images[:, 0::2, 1::2], images[:, 1::2, 0::2], images[:, 1::2, 1::2])).astype(np.int8)


def fully_connected_int8(values, weights, bias, multiplier=1, shift=0):
    values = np.asarray(values, dtype=np.int8).reshape(-1).astype(np.int64)
    weights = np.asarray(weights, dtype=np.int8)
    bias = np.asarray(bias, dtype=np.int32)
    accum = values @ weights.astype(np.int64)
    return requantize(accum, bias, multiplier, shift, False)


def fully_connected_int8_batch(values, weights, bias, multiplier=1, shift=0):
    values = np.asarray(values, dtype=np.int8)
    weights = np.asarray(weights, dtype=np.int8)
    bias = np.asarray(bias, dtype=np.int32)
    accum = values.astype(np.int64) @ weights.astype(np.int64)
    return requantize(accum, bias, multiplier, shift, False)


def pack_feature_map(image):
    image = np.asarray(image, dtype=np.int8)
    height, width, channels = image.shape
    if channels % N:
        raise ValueError("channel count must be divisible by four")
    words = []
    for y in range(height):
        for x in range(width):
            for group in range(channels // N):
                word = 0
                for lane in range(N):
                    word |= (int(image[y, x, group * N + lane]) & 0xff) << (lane * 8)
                words.append(word)
    return words


def pack_weights(weights):
    weights = np.asarray(weights, dtype=np.int8)
    kernel_h, kernel_w, input_channels, output_channels = weights.shape
    if kernel_h != kernel_w or input_channels % N or output_channels % N:
        raise ValueError("weights must use square kernels and channel counts divisible by four")
    channel_groups = input_channels // N
    chunks = kernel_h * kernel_w * channel_groups
    words = []
    for output_group in range(output_channels // N):
        for chunk in range(chunks):
            ky = chunk // (kernel_w * channel_groups)
            kx = (chunk // channel_groups) % kernel_w
            input_group = chunk % channel_groups
            for row in range(N):
                word = 0
                for lane in range(N):
                    value = weights[ky, kx, input_group * N + row, output_group * N + lane]
                    word |= (int(value) & 0xff) << (lane * 8)
                words.append(word)
    return words


def pack_biases(bias):
    bias = np.asarray(bias, dtype=np.int32).reshape(-1)
    if bias.size % N:
        raise ValueError("bias count must be divisible by four")
    result = []
    for start in range(0, bias.size, N):
        word = 0
        for lane in range(N):
            word |= (int(bias[start + lane]) & 0xffffffff) << (lane * 32)
        result.append(word)
    return result


def pack_instruction(config):
    fields = (
        ("op", 88, 2), ("in_h", 80, 8), ("in_w", 72, 8), ("in_c", 62, 10),
        ("out_c", 54, 8), ("kernel", 50, 4), ("stride", 46, 4), ("pad", 42, 4),
        ("relu_en", 41, 1), ("w_base", 29, 12), ("b_base", 21, 8),
        ("quant_mult", 5, 16), ("quant_shift", 0, 5),
    )
    instruction = 0
    for name, low, width in fields:
        instruction |= (int(config.get(name, 0)) & ((1 << width) - 1)) << low
    return instruction


def write_hex_words(path, words, width):
    with open(path, "w", encoding="ascii") as stream:
        for word in words:
            stream.write(f"{int(word) & ((1 << width) - 1):0{width // 4}x}\n")

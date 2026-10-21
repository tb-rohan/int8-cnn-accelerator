# Sample Inference Inputs

This directory contains tracked sample inputs to test single-image inference with `python/run_rtl_manual.py`:

- **`sample_digit7.png`**: A 28x28 grayscale image of a handwritten digit "7" extracted from the standard MNIST test partition (Sample index 0).
- **`sample_digit7.npy`**: The normalized floating-point array ($28 \times 28$, values in range $[0.0, 1.0]$) corresponding to `sample_digit7.png`.

## Running Manual Inference

### Using the PNG Image:
```powershell
python python\run_rtl_manual.py examples\sample_digit7.png
```

### Using the Raw NumPy Array:
```powershell
python python\run_rtl_manual.py --raw examples\sample_digit7.npy
```

### Expected Output:
- **Predicted Digit:** `7` (Winning score: 47)
- **Class Scores (0–9):** `[-17, -36, -3, 8, -53, -13, -65, 47, -16, 1]`
- **RTL / Python Match:** `MATCH (12/12 bytes bit-exact)`
- **Accelerator Execution Latency:** `53,836 clock cycles`

## Attribution
The sample digit is sourced from the MNIST database of handwritten digits:
- **Authors:** Yann LeCun, Corinna Cortes, and Christopher J.C. Burges.
- **URL:** http://yann.lecun.com/exdb/mnist/

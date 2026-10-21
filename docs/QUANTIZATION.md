# Neural Network Quantization & Integer Arithmetic Specification

**Project:** Standalone INT8 CNN Hardware Accelerator  
**Baseline Model:** PyTorch FP32 Convolutional Neural Network  
**Quantization Scheme:** Post-Training Calibrated Symmetric Signed INT8  
**Dataset:** MNIST (10,000 standard test images)  
**Accuracy:** **96.39% FP32 $\rightarrow$ 96.44% INT8 (+0.05% delta)**  

---

## 1. Network Topology

The model is a lightweight 5-layer CNN tailored for spatial hardware acceleration:

```
Input: 28 x 28 x 1 (Padded to 4 channels: 28 x 28 x 4)
  │
  ▼
Layer 0: Conv2D (Kernel: 3x3, In: 4, Out: 8, Stride: 1, Pad: 1, Bias: True)
  │
  ▼
Layer 1: MaxPool2D (Receptive Field: 2x2, Stride: 2) -> Output: 14 x 14 x 8
  │
  ▼
Layer 2: Conv2D (Kernel: 3x3, In: 8, Out: 8, Stride: 1, Pad: 1, Bias: True)
  │
  ▼
Layer 3: MaxPool2D (Receptive Field: 2x2, Stride: 2) -> Output: 7 x 7 x 8
  │
  ▼
Layer 4: Fully Connected / Conv2D (Kernel: 1x1, In: 392, Out: 12, Bias: True)
  │
  ▼
Output: 12 Signed Values (10 valid digit logits + 2 padding lanes)
```

---

## 2. Symmetric INT8 Quantization Scheme

The design uses symmetric signed INT8 quantization with zero point $Z=0$ for all weights, biases, and feature activations.

### 2.1 Mapping Formula
Real-valued tensor $x \in \mathbb{R}$ is mapped to signed 8-bit integer $q \in [-128, +127]$:
$$q = \text{clamp}\left(\left\lfloor \frac{x}{S} + 0.5 \right\rfloor, -128, 127\right)$$
where $S$ is the positive floating-point scale factor.

### 2.2 Scale Factor Calibration
Scales are calibrated using a dedicated subset of 1,024 MNIST training images (seed 2027) by recording dynamic ranges:
$$S = \frac{\max(|x|)}{127}$$
From `artifacts/mnist_int8_evaluation.json`:
- **Input Scale ($S_{\text{in}}$):** $0.007874016$ ($\approx 1/127$)
- **Layer 0 Activation Scale ($S_{a0}$):** $0.026722976$
- **Layer 2 Activation Scale ($S_{a2}$):** $0.091526707$
- **Layer 4 Activation Scale ($S_{a4}$):** $0.257463711$

---

## 3. Fixed-Point Requantization (`round_shift`)

In convolutional and fully connected layers, multiplying signed INT8 inputs by signed INT8 weights produces signed 16-bit products that accumulate into signed 32-bit accumulators:
$$P_i = \sum_{j} A_j \cdot W_{i,j} + B_i$$

To scale the 32-bit accumulator value back to the next layer's 8-bit dynamic range, the exact mathematical scaling factor is:
$$M_{\text{real}} = \frac{S_{\text{in}} \cdot S_{w}}{S_{\text{out}}}$$

In hardware, floating-point division is avoided by factoring $M_{\text{real}}$ into an integer multiplier $M \in [0, 65535]$ and a right shift $S \in [0, 31]$:
$$M_{\text{real}} \approx \frac{M}{2^S}$$

### Calibrated Layer Multipliers and Shifts:

| Layer | Type | Multiplier ($M$) | Right Shift ($S$) | Effective Scale ($M / 2^S$) |
| :---: | :---: | :---: | :---: | :---: |
| **Layer 0** | Conv2D | `46477` | `25` | $0.00138515$ |
| **Layer 2** | Conv2D | `42739` | `25` | $0.00127376$ |
| **Layer 4** | Fully Connected | `46610` | `25` | $0.00138912$ |

### Round-Half-Up Requantization
Hardware and Python golden reference implement symmetric round-half-up (add half and arithmetic right shift / round half towards $+\infty$) for fixed-point requantization:
```systemverilog
// post_proc.sv stage 2 rounding logic:
if (shift_stage[1] != 0)
  shifted_stage[j] <= ($signed({product_stage[j][48], product_stage[j]}) +
      (50'sd1 <<< (shift_stage[1] - 1'b1))) >>> shift_stage[1];
else
  shifted_stage[j] <= $signed({product_stage[j][48], product_stage[j]});
```
This is bit-exact with the Python integer golden model (`python/golden.py`):
```python
if shift:
    value = (value + (1 << (shift - 1))) >> shift
```
Exact halfway ties (e.g. $+0.5 \rightarrow +1$, $-0.5 \rightarrow 0$, $-1.5 \rightarrow -1$) round upwards towards $+\infty$, avoiding the need for multi-bit fraction inspection and parity logic. Note that offline weight and bias quantization from floating-point PyTorch tensors (`python/quantize.py`) uses `np.rint` (round-to-nearest-even).

---

## 4. Empirical Evaluation & Accuracy Results

Executed across the entire 10,000-image MNIST test partition via `python/evaluate_mnist.py`:

```powershell
python python\evaluate_mnist.py --checkpoint artifacts\mnist_cnn.pt --data data --samples 10000
```

### Accuracy Comparison:

| Metric | PyTorch FP32 Baseline | Calibrated INT8 Integer Model | Delta |
| :--- | :---: | :---: | :---: |
| **Total Test Images** | 10,000 | 10,000 | — |
| **Correct Classifications** | 9,639 | 9,644 | +5 images |
| **Incorrect Classifications** | 361 | 356 | -5 images |
| **Top-1 Accuracy** | **96.3900%** | **96.4400%** | **+0.0500%** |

*Note on Quantization Performance:* The slight $+0.05\%$ accuracy gain observed in the INT8 model is a well-documented phenomenon in small convolutional networks where integer quantization acts as an implicit regularizer, pruning low-amplitude activation noise.

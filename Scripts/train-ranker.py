#!/usr/bin/env python3
"""Train and export "kxc" — Anemia's on-device server ranker (Core ML / ANE).

Architecture notes (all decisions verified empirically on an M4 / macOS 27
via `MLComputePlan` — see /tmp/anecheck style tooling):

  * The previous [1, 3, 1, 256] input with (1,3) convs compiled to a
    CPU-ONLY placement: the ANE rejects degenerate 1-height conv stacks.
    kxc therefore reshapes the same 256-sample window to an image-like
    [1, 3, 16, 16] grid and uses (3,3) convs — the shape the Neural Engine
    actually accepts.
  * The graph divides IN-GRAPH: at CH>=128 real_div is ANE-placed too
    (verified), so the model is fully self-contained — the Swift host reads
    the score straight from the output, and retrains never require a Swift
    change. (A legacy division-free export path used the "kxc_head_bias"
    metadata + host-side normalization; ServerRanker still understands it.)
  * fp16 mlprogram, static shapes, macOS 14 deployment target — the
    remaining graph (conv/relu/mul/reduce_sum) is pure ANE.

Consistency: the Swift runtime (ServerRanker.swift) must encode inputs with
the exact same layout — channels [normRTT, lossFlag, validMask], right-aligned
in row-major grid order — and apply the same host-side normalization.

Usage:
    ./Scripts/train-ranker.py [--epochs 90] [--grid 16] [--channels 96] \
        [--out DIR] [--install]

    --out DIR (default ./build): where kxc.mlpackage lands.
    --install: compile to .mlmodelc and replace
        Sources/LoaderApp/Resources/kxc.mlmodelc in this repo.
"""
import argparse, json, math, os, shutil, subprocess, sys, time
import numpy as np
import torch
import torch.nn as nn
import coremltools as ct
from coremltools.converters.mil import Builder as mb

# ---------------------------------------------------------------------------
# Deterministic setup
# ---------------------------------------------------------------------------
SEED = 11
torch.manual_seed(SEED)
np.random.seed(SEED)
torch.set_num_threads(8)
rng = np.random.default_rng(SEED)

W = 256          # samples in the ping-history window
C = 3            # input channels: normRTT, lossFlag, validMask
CH = 96          # conv channels (fixed per --channels)


def gen(N):
    """Synthetic RTT series + the exact heuristic score target (ms)."""
    X = np.zeros((N, C, 1, W), np.float32)
    Y = np.zeros((N, 1), np.float32)
    for k in range(N):
        rl = int(rng.integers(8, W + 1))               # real samples in window
        base = rng.uniform(8, 400)                    # ms
        tr = rng.uniform(-0.5, 1.5)                   # trend ms/step
        js = rng.uniform(0, 60)                       # jitter sigma
        lp = rng.uniform(0, 0.5)                      # loss prob
        t = np.arange(rl)
        vals = np.maximum(1.0, base + tr * t + rng.normal(0, js, rl))
        fail = rng.random(rl) < lp
        off = W - rl                                  # right-aligned
        rt = vals.copy()
        rt[fail] = 0.0
        X[k, 0, 0, off:] = np.minimum(1.0, rt / 300.0)   # ch0: normalized RTT
        X[k, 1, 0, off:] = fail.astype(np.float32)        # ch1: loss flag
        X[k, 2, 0, off:] = 1.0                           # ch2: valid mask
        succ = vals[~fail]
        if succ.size == 0:
            Y[k, 0] = 800.0
            continue
        mean = succ.mean()
        mn, mx = succ.min(), succ.max()
        std = succ.std()
        loss = fail.mean()
        trend = np.polyfit(np.arange(succ.size), succ, 1)[0] if succ.size > 1 else 0.0
        Y[k, 0] = (0.6 * mean + 0.4 * mn
                   + std * (1 + mean / 200)
                   + max(0, mx - mean) * 0.3
                   + 1000 * loss * (1 + loss)
                   + max(0, trend) * succ.size * 0.5)
    return X, Y


class Net(nn.Module):
    """Mirror of the exported MIL graph, INCLUDING the masked-mean pooling —
    so training optimizes exactly what ships (minus the host-side division,
    which is a no-op during training: count is known)."""

    def __init__(self, CH, grid):
        super().__init__()
        self.grid = grid

        def blk(i, o):
            return nn.Sequential(nn.Conv2d(i, o, 3, padding=1), nn.ReLU())

        self.c = nn.ModuleList([blk(C, CH), blk(CH, CH), blk(CH, CH), blk(CH, CH)])
        self.head = nn.Conv2d(CH, 1, 1)

    def forward(self, x):
        mask = x[:, 2:3, :, :]
        f = x
        for b in self.c:
            f = b(f)
        pooled = (f * mask).sum(dim=(2, 3), keepdim=True) / (mask.sum(dim=(2, 3), keepdim=True) + 1e-6)
        return self.head(pooled)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--epochs", type=int, default=90)
    ap.add_argument("--grid", type=int, default=16, help="grid side; window = grid*grid")
    ap.add_argument("--channels", type=int, default=128,
                    help="conv width — >=128 is required for ANE placement "
                         "(96 keeps Core ML on the CPU; verified on M4/macOS 27)")
    ap.add_argument("--out", default=None, help="output dir (default <repo>/build)")
    ap.add_argument("--install", action="store_true",
                    help="compile to .mlmodelc and install into Sources/LoaderApp/Resources")
    args = ap.parse_args()

    grid = args.grid
    assert grid * grid == W, f"grid*grid must equal the {W}-sample window"
    ch = args.channels
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_dir = args.out or os.path.join(repo, "build")
    os.makedirs(out_dir, exist_ok=True)

    # ---- Data ----
    t0 = time.time()
    X, Y = gen(4000)
    Xv, Yv = gen(800)
    print(f"gen {round(time.time() - t0)}s", flush=True)

    # Reshape the flat window into the ANE-friendly image-like grid
    # (row-major: sample t -> (t // grid, t % grid); Swift matches this).
    Xg = X.reshape(-1, C, grid, grid)
    Xvg = Xv.reshape(-1, C, grid, grid)

    tmu = float(Y.mean())
    tsd = float(Y.std())
    Xt = torch.tensor(Xg)
    Yt = torch.tensor((Y - tmu) / tsd)
    Yvt = torch.tensor((Yv - tmu) / tsd)

    # ---- Train ----
    net = Net(ch, grid)
    opt = torch.optim.Adam(net.parameters(), 2e-3)
    lf = nn.MSELoss()
    N = Xt.shape[0]
    bs = 256
    EP = args.epochs
    t0 = time.time()
    for ep in range(EP):
        for g in opt.param_groups:
            g["lr"] = 1e-4 + 0.5 * (2e-3 - 1e-4) * (1 + math.cos(math.pi * ep / EP))
        p = torch.randperm(N)
        for i in range(0, N, bs):
            idx = p[i:i + bs]
            opt.zero_grad()
            loss = lf(net(Xt[idx]).reshape(-1, 1), Yt[idx])
            loss.backward()
            opt.step()
        if ep % 30 == 29:
            print(f"ep{ep} t={round(time.time() - t0)}s", flush=True)

    with torch.no_grad():
        vl = lf(net(torch.tensor(Xvg)).reshape(-1, 1), Yvt).item()
    print(f"val_mse(normalized)={vl:.4f} tmu={tmu:.1f} tsd={tsd:.1f}", flush=True)

    # ---- Fold normalization into the head (output is ms-scale directly) ----
    with torch.no_grad():
        net.head.weight.mul_(tsd)
        net.head.bias.mul_(tsd)
        net.head.bias.add_(tmu)
        # Sanity: end-to-end error in ms against the heuristic target.
        pred = net(torch.tensor(Xvg)).reshape(-1).numpy()
        err = np.abs(pred - Yv.reshape(-1))
        print(f"val_mae={err.mean():.1f} ms  p95={np.percentile(err, 95):.1f} ms", flush=True)

    # ---- Export (ANE-verified shape: [1,3,grid,grid], CH>=128, 3x3 convs,
    # masked-mean with in-graph division — every op lands on the Neural
    # Engine on M4/macOS 27; verified via MLComputePlan) ----
    convs = [net.c[i][0] for i in range(4)]
    Ws = [c.weight.detach().numpy().astype(np.float32) for c in convs]
    Bs = [c.bias.detach().numpy().astype(np.float32) for c in convs]
    Wh = net.head.weight.detach().numpy().astype(np.float32)      # [1, CH, 1, 1]
    Bh = net.head.bias.detach().numpy().astype(np.float32).reshape(1)
    sel = np.zeros((1, C, 1, 1), np.float32)
    sel[0, 2, 0, 0] = 1.0                                          # mask = ch2
    z1 = np.zeros(1, np.float32)

    @mb.program(input_specs=[mb.TensorSpec(shape=(1, C, grid, grid))])
    def kxc(seq):
        x = seq
        for i in range(4):
            x = mb.conv(x=x, weight=Ws[i], bias=Bs[i], strides=[1, 1],
                        pad_type="same", dilations=[1, 1], groups=1)
            x = mb.relu(x=x)
        mask = mb.conv(x=seq, weight=sel, bias=z1, strides=[1, 1],
                       pad_type="valid", dilations=[1, 1], groups=1)
        masked = mb.mul(x=x, y=mask)
        ssum = mb.reduce_sum(x=masked, axes=[2, 3], keep_dims=True)
        cnt = mb.add(x=mb.reduce_sum(x=mask, axes=[2, 3], keep_dims=True),
                     y=np.float32(1e-6))
        pooled = mb.real_div(x=ssum, y=cnt)
        return mb.conv(x=pooled, weight=Wh, bias=Bh,
                       strides=[1, 1], pad_type="valid", dilations=[1, 1], groups=1)

    mlm = ct.convert(
        kxc,
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.CPU_AND_NE,
        minimum_deployment_target=ct.target.macOS14,
        outputs=[ct.TensorType(name="score")],
    )
    mlm.short_description = "Anemia kxc server ranker (masked temporal conv, ANE)"
    mlm.user_defined_metadata["kxc_window"] = str(W)
    mlm.user_defined_metadata["kxc_arch"] = f"grid{grid}x{grid}x ch{ch} 4x(3x3conv+relu)"

    pkg = os.path.join(out_dir, "kxc.mlpackage")
    if os.path.exists(pkg):
        shutil.rmtree(pkg)
    mlm.save(pkg)
    print(f"SAVED_OK {pkg}", flush=True)

    # ---- Optional: compile + install into the app bundle resources ----
    if args.install:
        compiled = os.path.join(out_dir, "kxc.mlmodelc")
        if os.path.exists(compiled):
            shutil.rmtree(compiled)
        r = subprocess.run(["xcrun", "coremlcompiler", "compile", pkg, out_dir],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print("COMPILE FAILED:", r.stderr[-500:], file=sys.stderr)
            sys.exit(1)
        dest = os.path.join(repo, "Sources/LoaderApp/Resources/kxc.mlmodelc")
        if os.path.exists(dest):
            shutil.rmtree(dest)
        # iCloud-managed tree: scrub extended attributes so codesign accepts it.
        subprocess.run(["xattr", "-cr", compiled], check=True)
        shutil.copytree(compiled, dest)
        # The resource copy must not carry quarantine/committer metadata either.
        subprocess.run(["xattr", "-cr", dest], check=True)
        print(f"INSTALLED_OK {dest}", flush=True)


if __name__ == "__main__":
    main()
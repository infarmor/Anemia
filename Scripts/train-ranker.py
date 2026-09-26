#!/usr/bin/env python3
"""Train and export "kxc" — Anemia's on-device server ranker (Core ML / ANE).

v3.1 — the FORECAST model, second attempt. What v3.0's failure taught:

  * v3.0 changed the objective — see a 256-sample window, predict the
    heuristic score of the NEXT H samples — and it lost to the naive
    baseline (val MAE 255.5 vs 241.9, Spearman 0.353 vs 0.435; val MSE 1.19
    on a normalized target = worse than predicting the mean). The model
    didn't underperform because forecasting is impossible: the synthetic
    generator redrew jitter/loss/trend INDEPENDENTLY for every segment, so
    across the past/future boundary only the latency level persisted. The
    only learnable signal was the level — which is exactly what the naive
    baseline already predicts. No architecture can beat a baseline on
    signal that isn't there.

  * v3.1 makes the future actually predictable from the past, the way real
    servers are: each series has a persistent CHARACTER (base latency,
    jitter scale, loss scale) that every regime perturbs instead of
    replacing; regimes are long enough to usually span the boundary;
    throttle steps and recoveries stick. Now "deteriorating link" and
    "recovered link" are genuinely different forecasts.

  * Recency-weighted pooling: v3.0's masked mean averaged the whole window
    uniformly, so the head was blind to WHERE features occurred — the tail
    of the window (the most predictive part) counted the same as 250
    samples ago. ch2 now carries exponential recency weights (newest = 1,
    DECAY**age backwards), so the pooled head sees the recent regime. The
    Swift encoder mirrors this via the model's kxc_decay metadata (absent =
    legacy uniform mask, so old models keep working).

  * Honest scoreboard, two baselines:
      naive-full  — heuristic over the whole visible window (what the app
                    falls back to; what v2 effectively shipped)
      naive-recent— heuristic over the last H visible samples (the cheap
                    "just look at the tail" predictor)
    The model must beat BOTH on MAE and on Spearman, or it is not smarter
    than the thing it replaces — and --install REFUSES (exit 2).

  * Learning is observable: train/val loss printed every 10 epochs, so a
    diverged run is visible long before the 70-minute mark.

  * Residual conv stack (still ANE-shaped): stem + 3 residual blocks
    (mb.add is ANE-placed), recency-weighted masked-mean head.

Architecture constraints (all verified empirically on an M4 / macOS 27 via
MLComputePlan — see aneck check at the end of this script):

  * [1, 3, 16, 16] image-like grid, (3,3) convs — the ANE rejects
    degenerate 1-height conv stacks.
  * CH >= 128 or Core ML falls back to the CPU.
  * fp16 mlprogram, static shapes, in-graph real_div for the masked mean —
    the whole graph is Neural-Engine placed.
  * The Swift host (ServerRanker.swift) encodes inputs with the exact same
    layout — channels [normRTT, lossFlag, recencyMask], right-aligned
    row-major — and reads the score straight from the output.

Usage:
    .venv/bin/python Scripts/train-ranker.py [--epochs 120] [--install]

    --install: compile to .mlmodelc and replace
        Sources/LoaderApp/Resources/kxc.mlmodelc in this repo.
        Refuses unless the model beats both baselines (--force overrides,
        which you should never use for a shipping model).
"""
import argparse, math, os, shutil, subprocess, sys, time
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

W = 256          # samples in the visible ping-history window
H = 32           # future horizon the model must predict the score of
C = 3            # input channels: normRTT, lossFlag, recencyMask
DECAY = 0.98     # recency weight per sample: ch2 = DECAY**age (newest = 1)


def heuristic(vals, fail):
    """The ranking target: the app's hand-crafted badness score over a series.
    Kept in lockstep with rankingScore() in ServerRanker.swift — INCLUDING
    the all-fail sentinel: Swift returns 100_000 when no probe in the window
    succeeded, so training must not teach the model that total failure is a
    mild ~800 (a server with ~100% loss but a single valid probe would then
    outrank a slow-but-alive one in the app's ranking)."""
    succ = vals[~fail]
    if succ.size == 0:
        return 100_000.0
    mean = succ.mean()
    mn, mx = succ.min(), succ.max()
    std = succ.std()
    loss = fail.mean()
    trend = np.polyfit(np.arange(succ.size), succ, 1)[0] if succ.size > 1 else 0.0
    return (0.6 * mean + 0.4 * mn
            + std * (1 + mean / 200)
            + max(0, mx - mean) * 0.3
            + 1000 * loss * (1 + loss)
            + max(0, trend) * succ.size * 0.5)


def series(rl):
    """One RTT series of `rl` samples with PERSISTENT server character.

    A real server has character: a flaky link stays flaky, a throttled link
    stays throttled, a quiet one stays quiet. So the character — base
    latency, jitter scale, loss scale — is drawn ONCE per series and every
    regime is a perturbation of it, never a fresh independent draw. Regime
    segments are long (up to half the series, at least a few horizons) so
    they usually span the past/future boundary, and state changes persist:
    a throttle step raises base latency and jitter until a recovery
    happens. The forecast target is therefore genuinely learnable from the
    visible window — which v3.0's independent-per-segment generator made
    impossible.

    Regimes (perturbations of the persistent character):
      stable   — jitter/loss crushed (the low-score anchor)
      noisy    — jitter/loss scaled up around character, iid-ish loss
      bursty   — Gilbert-Elliot loss runs around the characteristic loss
      step     — throttle: base latency + jitter jump PERSISTENTLY
      recover  — link gets better: base latency drops persistently
    Jitter is AR(1)-correlated everywhere, like real queueing delay.
    """
    base = rng.uniform(8, 300)
    char_js = rng.uniform(1.5, 45)    # characteristic jitter scale
    char_lp = rng.uniform(0, 0.30)    # characteristic loss scale
    vals = np.empty(rl)
    fail = np.zeros(rl, bool)
    ar = 0.0
    js = char_js                        # current jitter scale (persists)
    i = 0
    while i < rl:
        regime = rng.choice(["stable", "noisy", "bursty", "step", "recover"],
                            p=[0.24, 0.28, 0.18, 0.16, 0.14])
        # Long segments: a regime usually outlives the forecast horizon,
        # so the boundary regime often continues into the future.
        lo = max(12, min(2 * H, rl // 3))
        hi = max(lo + 1, rl // 2)
        seg = int(rng.integers(lo, hi)) if rl > 24 else rl
        seg = min(seg, rl - i)
        if regime == "stable":
            s_js, s_lp = js * 0.15, char_lp * 0.05
            tr = rng.uniform(-0.05, 0.05)
        elif regime == "noisy":
            s_js = js * rng.uniform(0.7, 1.7)
            s_lp = char_lp * rng.uniform(0.5, 1.8)
            tr = rng.uniform(-0.5, 1.5)
        elif regime == "bursty":
            s_js = js * rng.uniform(0.5, 1.2)
            s_lp = min(0.6, char_lp * rng.uniform(1.2, 3.0) + 0.02)
            tr = rng.uniform(-0.3, 1.0)
        elif regime == "step":
            # A throttle event: latency and jitter step up — and STAY up.
            base = min(420.0, base + rng.uniform(30, 250))
            js = char_js * rng.uniform(1.5, 3.0)
            s_js, s_lp = js, char_lp * rng.uniform(0.5, 1.5)
            tr = rng.uniform(-0.2, 0.8)
        else:  # recover — was bad, gets better (persistently)
            base = max(10.0, base * rng.uniform(0.4, 0.75))
            js = char_js
            s_js, s_lp = js * rng.uniform(0.3, 0.7), char_lp * rng.uniform(0, 0.5)
            tr = rng.uniform(-1.5, -0.2)
        for k in range(seg):
            # AR(1) jitter: correlated sample to sample, like queue delay.
            ar = 0.75 * ar + rng.normal(0, s_js) * (1 - 0.75) ** 0.5
            vals[i + k] = max(1.0, base + tr * (i + k) + ar)
        if regime == "bursty":
            # Gilbert-Elliot: alternating bad/good runs with high/low loss.
            bad, p_bad = s_lp, 0.5
            j = 0
            while j < seg:
                run = int(rng.integers(1, 6))
                in_bad = rng.random() < p_bad
                end = min(j + run, seg)
                fail[i + j:i + end] = rng.random(end - j) < (bad if in_bad else bad * 0.15)
                j = end
        else:
            fail[i:i + seg] = rng.random(seg) < min(0.6, s_lp)
        i += seg
    return vals, fail


def gen(N):
    """Synthetic visible-window + held-out-future pairs.

    X: the [C, 1, W] visible window (right-aligned, like the Swift encoder).
       ch2 carries recency weights DECAY**age, not a uniform 1.
    Y:    heuristic score over the NEXT H samples — the forecast target.
    Ybase:  heuristic over the WHOLE visible window — the naive-full
            baseline (what the app's fallback and v2 effectively ship).
    Ybase2: heuristic over the LAST H visible samples — the naive-recent
            baseline (the cheap "look at the tail" predictor).
    """
    X = np.zeros((N, C, 1, W), np.float32)
    Y = np.zeros((N, 1), np.float32)
    Ybase = np.zeros((N, 1), np.float32)
    Ybase2 = np.zeros((N, 1), np.float32)
    w_recent = DECAY ** np.arange(W - 1, -1, -1, dtype=np.float64)   # age weights
    for k in range(N):
        # Visible occupancy: full / short / in-between, so every fill level —
        # and its grid edge artifacts — is represented.
        r = rng.random()
        if r < 0.18:
            rl = W
        elif r < 0.42:
            rl = int(rng.integers(8, 48))
        else:
            rl = int(rng.integers(8, W + 1))
        total = rl + H
        vals, fail = series(total)
        past_v, past_f = vals[:rl], fail[:rl]
        fut_v, fut_f = vals[rl:], fail[rl:]
        off = W - rl
        rt = past_v.copy()
        rt[past_f] = 0.0
        X[k, 0, 0, off:] = np.minimum(1.0, rt / 300.0)          # ch0: normalized RTT
        X[k, 1, 0, off:] = past_f.astype(np.float32)           # ch1: loss flag
        X[k, 2, 0, off:] = w_recent[-rl:]                       # ch2: recency mask
        Y[k, 0] = heuristic(fut_v, fut_f)
        Ybase[k, 0] = heuristic(past_v, past_f)
        n2 = min(H, rl)
        Ybase2[k, 0] = heuristic(past_v[-n2:], past_f[-n2:])
    return X, Y, Ybase, Ybase2


class Net(nn.Module):
    """Mirror of the exported MIL graph, INCLUDING the recency-weighted
    masked-mean pooling.

    Stem (C→CH) then 3 residual blocks (conv-relu-conv + add, post-add
    relu) — deeper than v2's flat stack, with identity paths so the gradient
    survives. The pooling head multiplies features by the recency mask and
    normalizes by its sum, so the head sees an average weighted toward the
    window's end. `mb.add` is ANE-placed, so the residual layout keeps the
    whole graph on the Neural Engine.
    """

    def __init__(self, CH, grid):
        super().__init__()
        self.grid = grid
        self.stem = nn.Sequential(nn.Conv2d(C, CH, 3, padding=1), nn.ReLU())
        self.ra = nn.ModuleList()
        self.rb = nn.ModuleList()
        for _ in range(3):
            self.ra.append(nn.Conv2d(CH, CH, 3, padding=1))
            self.rb.append(nn.Conv2d(CH, CH, 3, padding=1))
        self.head = nn.Conv2d(CH, 1, 1)

    def forward(self, x):
        mask = x[:, 2:3, :, :]
        f = self.stem(x)
        for a, b in zip(self.ra, self.rb):
            f = torch.relu(f + b(torch.relu(a(f))))
        pooled = (f * mask).sum(dim=(2, 3), keepdim=True) / (mask.sum(dim=(2, 3), keepdim=True) + 1e-6)
        return self.head(pooled)


def spearman(a, b):
    """Rank correlation — the metric that matters for *ordering* servers."""
    ra = np.argsort(np.argsort(a)).astype(np.float64)
    rb = np.argsort(np.argsort(b)).astype(np.float64)
    ra = (ra - ra.mean()) / (ra.std() + 1e-9)
    rb = (rb - rb.mean()) / (rb.std() + 1e-9)
    return float((ra * rb).mean())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--epochs", type=int, default=120)
    ap.add_argument("--grid", type=int, default=16, help="grid side; window = grid*grid")
    ap.add_argument("--channels", type=int, default=128,
                    help="conv width — >=128 is required for ANE placement "
                         "(96 keeps Core ML on the CPU; verified on M4/macOS 27)")
    ap.add_argument("--out", default=None, help="output dir (default <repo>/build)")
    ap.add_argument("--install", action="store_true",
                    help="compile to .mlmodelc and install into Sources/LoaderApp/Resources")
    ap.add_argument("--force", action="store_true",
                    help="install even if the model fails the baseline check "
                         "(for experiments only — never for a shipping model)")
    args = ap.parse_args()

    grid = args.grid
    assert grid * grid == W, f"grid*grid must equal the {W}-sample window"
    ch = args.channels
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_dir = args.out or os.path.join(repo, "build")
    os.makedirs(out_dir, exist_ok=True)

    # ---- Data ----
    t0 = time.time()
    X, Y, Ybase, Ybase2 = gen(9000)
    Xv, Yv, Ybase_v, Ybase2_v = gen(2000)

    # The all-fail sentinel (100_000, matching Swift) must not poison the
    # target normalization: a handful of such samples would balloon Y.std()
    # and flatten every ordinary target into noise. Clip the training/eval
    # targets to a cap that still ranks total failure far above the worst
    # plausible live window (a 60%-loss, 300 ms server scores ~2000 here).
    # Swift's own ranking never sees the raw sentinel through the model —
    # the model output only ever feeds comparisons, and ~4000 keeps a dead
    # window ranked worse than any living one.
    TARGET_CAP = 4000.0
    Y = np.minimum(Y, TARGET_CAP)
    Ybase = np.minimum(Ybase, TARGET_CAP)
    Ybase2 = np.minimum(Ybase2, TARGET_CAP)
    Yv = np.minimum(Yv, TARGET_CAP)
    Ybase_v = np.minimum(Ybase_v, TARGET_CAP)
    Ybase2_v = np.minimum(Ybase2_v, TARGET_CAP)
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
        run_tr = 0.0
        nb = 0
        for i in range(0, N, bs):
            idx = p[i:i + bs]
            opt.zero_grad()
            loss = lf(net(Xt[idx]).reshape(-1, 1), Yt[idx])
            loss.backward()
            opt.step()
            run_tr += loss.item()
            nb += 1
        # Learning is visible as it happens: a diverged or stalled run shows
        # up here, long before the hour mark.
        if ep % 10 == 9 or ep == EP - 1:
            with torch.no_grad():
                vl = lf(net(torch.tensor(Xvg)).reshape(-1, 1), Yvt).item()
            print(f"ep{ep:3d} t={round(time.time() - t0)}s "
                  f"train_mse={run_tr / nb:.4f} val_mse={vl:.4f}", flush=True)

    # ---- Fold normalization into the head (output is ms-scale directly) ----
    with torch.no_grad():
        net.head.weight.mul_(tsd)
        net.head.bias.mul_(tsd)
        net.head.bias.add_(tmu)

    # ---- The honest scoreboard: model vs two naive "describe the past" ----
    # All three predictors target the FUTURE-window heuristic.
    #   naive-full  — heuristic of the whole visible window (the app's
    #                 fallback; what v2 effectively shipped)
    #   naive-recent— heuristic of the last H visible samples (the cheap
    #                 "look at the tail" predictor)
    # The model must beat BOTH on MAE and Spearman, or it is not smarter
    # than the thing it replaces and must not ship.
    with torch.no_grad():
        pred = net(torch.tensor(Xvg)).reshape(-1).numpy()
    fut = Yv.reshape(-1)
    b1 = Ybase_v.reshape(-1)
    b2 = Ybase2_v.reshape(-1)
    err_m = np.abs(pred - fut)
    err_b1 = np.abs(b1 - fut)
    err_b2 = np.abs(b2 - fut)
    sp_m, sp_b1, sp_b2 = spearman(pred, fut), spearman(b1, fut), spearman(b2, fut)
    print(f"model        val_mae={err_m.mean():.1f} ms  p95={np.percentile(err_m, 95):.1f} ms  "
          f"spearman={sp_m:.3f}", flush=True)
    print(f"naive-full   val_mae={err_b1.mean():.1f} ms  p95={np.percentile(err_b1, 95):.1f} ms  "
          f"spearman={sp_b1:.3f}", flush=True)
    print(f"naive-recent val_mae={err_b2.mean():.1f} ms  p95={np.percentile(err_b2, 95):.1f} ms  "
          f"spearman={sp_b2:.3f}", flush=True)
    better = (err_m.mean() < err_b1.mean() and err_m.mean() < err_b2.mean()
              and sp_m > sp_b1 and sp_m > sp_b2)
    print(f"MODEL_BEATS_NAIVE={'yes' if better else 'NO'}", flush=True)

    # ---- Export (ANE-verified shape: [1,3,grid,grid], CH>=128, 3x3 convs,
    # residual adds + recency-weighted masked-mean with in-graph division —
    # every op lands on the Neural Engine on M4/macOS 27; verified via
    # MLComputePlan) ----
    Ws = [net.stem[0].weight.detach().numpy().astype(np.float32)]
    Bs = [net.stem[0].bias.detach().numpy().astype(np.float32)]
    for a, b in zip(net.ra, net.rb):
        Ws.append(a.weight.detach().numpy().astype(np.float32))
        Bs.append(a.bias.detach().numpy().astype(np.float32))
        Ws.append(b.weight.detach().numpy().astype(np.float32))
        Bs.append(b.bias.detach().numpy().astype(np.float32))
    Wh = net.head.weight.detach().numpy().astype(np.float32)      # [1, CH, 1, 1]
    Bh = net.head.bias.detach().numpy().astype(np.float32).reshape(1)
    sel = np.zeros((1, C, 1, 1), np.float32)
    sel[0, 2, 0, 0] = 1.0                                          # mask = ch2
    z1 = np.zeros(1, np.float32)

    @mb.program(input_specs=[mb.TensorSpec(shape=(1, C, grid, grid))])
    def kxc(seq):
        x = mb.relu(x=mb.conv(x=seq, weight=Ws[0], bias=Bs[0], strides=[1, 1],
                              pad_type="same", dilations=[1, 1], groups=1))
        for i in range(3):
            y = mb.conv(x=x, weight=Ws[1 + 2 * i], bias=Bs[1 + 2 * i],
                        strides=[1, 1], pad_type="same", dilations=[1, 1], groups=1)
            y = mb.conv(x=mb.relu(x=y), weight=Ws[2 + 2 * i], bias=Bs[2 + 2 * i],
                        strides=[1, 1], pad_type="same", dilations=[1, 1], groups=1)
            x = mb.relu(x=mb.add(x=x, y=y))
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
    mlm.short_description = "Anemia kxc server ranker (residual temporal conv, recency-weighted forecast head, ANE)"
    mlm.user_defined_metadata["kxc_window"] = str(W)
    mlm.user_defined_metadata["kxc_horizon"] = str(H)
    mlm.user_defined_metadata["kxc_decay"] = str(DECAY)
    mlm.user_defined_metadata["kxc_arch"] = f"grid{grid}x{grid}x ch{ch} stem+3xres(3x3conv) forecast{H} decay{DECAY}"

    pkg = os.path.join(out_dir, "kxc.mlpackage")
    if os.path.exists(pkg):
        shutil.rmtree(pkg)
    mlm.save(pkg)
    print(f"SAVED_OK {pkg}", flush=True)

    # ---- Optional: compile + install into the app bundle resources ----
    if args.install:
        if not better and not args.force:
            print("INSTALL REFUSED: model does not beat both naive baselines "
                  "(--force for experiments only)", flush=True)
            sys.exit(2)
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

    # ---- Optional: where Core ML actually places the exported model ----
    # Compile once and let the user run /tmp/anecheck.swift against it:
    #   xcrun coremlcompiler compile build/kxc.mlpackage build
    #   swift /tmp/anecheck.swift build/kxc.mlmodelc


if __name__ == "__main__":
    main()
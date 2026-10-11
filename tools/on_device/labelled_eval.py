"""Evaluates a recogniser's per-box features against hand labels (Square / other / not a pack).
Usage: labelled_eval.py features.json [sim_field col_field]
Reports, tuned on half the shelves and scored on the other half (and swapped):
  share MAE vs the TRUE share, and pack accuracy (Square vs not, missed packs count as wrong)."""
import itertools
import json
import os
import sys

import numpy as np

LABEL_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "datasets", "eval", "fmcg-shelf-labels")
LABELS = {mode: json.load(open(os.path.join(LABEL_DIR, f"labels_{mode}.json"))) for mode in ("clean", "screen")}
SF, CF = (sys.argv[2], sys.argv[3]) if len(sys.argv) > 3 else ("sim", "col")


def iou(a, b):
    iw = max(0.0, min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0]))
    ih = max(0.0, min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1]))
    inter = iw * ih
    return inter / (a[2] * a[3] + b[2] * b[3] - inter) if inter else 0.0


def prepare(features):
    """Per image: arrays of box features, and each box's matched label (S/O/X) or None."""
    images = {"clean": [], "screen": []}
    for key, img in features.items():
        label_set, name = key.split("/", 1)
        truth = LABELS[label_set].get(name) or LABELS[label_set].get(name.replace(".jpg", ".png"))
        if truth is None:
            # keys are bare file names in some dumps
            truth = next((v for k, v in LABELS[label_set].items() if k.endswith("/" + name)), [])
        boxes = [b for b in img["boxes"] if b.get(SF) is not None or b.get("method") == "exact"]
        matched, used = [], set()
        for b in boxes:
            best, bj = 0.0, None
            for j, t in enumerate(truth):
                if j in used:
                    continue
                v = iou(b["box"], t["box"])
                if v > best:
                    best, bj = v, j
            if best >= 0.5:
                used.add(bj)
                matched.append(truth[bj]["label"])
            else:
                matched.append("X")
        n_s = sum(t["label"] == "S" for t in truth)
        n_o = sum(t["label"] == "O" for t in truth)
        exact = np.array([b.get("method") == "exact" for b in boxes], bool)
        images[label_set].append({
            "sim": np.array([1.0 if b.get("method") == "exact" else b[SF] for b in boxes]),
            "col": np.array([1.0 if b.get("method") == "exact" else b[CF] for b in boxes]),
            "det": np.array([b["det"] if b.get("det") is not None else 1.0 for b in boxes]),
            "bp": np.array([b.get("bp", 0.0) for b in boxes]), "bc": np.array([bool(b.get("bc")) for b in boxes]),
            "area": np.array([b["box"][2] * b["box"][3] for b in boxes]), "exact": exact,
            "truth": np.array(matched), "emb": np.array([b.get("emb", []) for b in boxes], np.float32), "true_share": 100 * n_s / max(1, n_s + n_o),
            "missed": (n_s + n_o) - sum(1 for m in matched if m in ("S", "O")), "n_so": n_s + n_o,
        })
    return images


def predict(img, K, T, Cmin, D, BR, F):
    brand = img["bc"] & (img["bp"] >= BR) & ~img["exact"]
    own = img["exact"] | (~brand & (img["sim"] + K * img["col"] >= T) & (img["col"] >= Cmin))
    other = brand | (~own & (img["det"] >= D))
    if F and own.sum() >= 3:
        other &= (img["area"] >= F * np.median(img["area"][own])) | brand
    return own, other


def score(images, cfg):
    share_err, correct, total = [], 0, 0
    for img in images:
        own, other = predict(img, *cfg)
        n = own.sum() + other.sum()
        share_err.append(abs(100 * own.sum() / max(1, n) - img["true_share"]))
        so = np.isin(img["truth"], ["S", "O"])
        correct += int(((img["truth"] == "S") & own)[so].sum() + ((img["truth"] == "O") & ~own)[so].sum())
        total += img["n_so"]
    return float(np.mean(share_err)), 100 * correct / max(1, total)


def configs(images):
    for K in (0.0, 0.5, 1.0):
        vals = np.concatenate([i["sim"] + K * i["col"] for i in images if len(i["sim"])])
        for T in np.linspace(*np.percentile(vals, (5, 97)), 30):
            for Cmin, D, BR, F in itertools.product((0, .12, .2, .28, .36, .44), (.1, .2, .3, .4), (.75, .85, .95, 1.01), (0, .35)):
                yield (K, round(float(T), 3), Cmin, D, BR, F)


def tune(images, objective):
    best = None
    for cfg in configs(images):
        mae, acc = score(images, cfg)
        value = mae if objective == "share" else -acc
        if best is None or value < best[0]:
            best = (value, cfg)
    return best[1]


def main():
  features = json.load(open(sys.argv[1]))
  data = prepare(features)
  for label in ("clean", "screen"):
      images = data[label]
      for objective in ("share", "accuracy"):
          a, b = images[0::2], images[1::2]
          ca, cb = tune(a, objective), tune(b, objective)
          mae = (score(b, ca)[0] * len(b) + score(a, cb)[0] * len(a)) / len(images)
          acc = (score(b, ca)[1] * len(b) + score(a, cb)[1] * len(a)) / len(images)
          print(f"{os.path.basename(sys.argv[1]):24} {label:6} tuned for {objective:8}: CV share MAE {mae:5.1f}  "
                f"CV pack accuracy {acc:5.1f}%  (detector found {100 - 100 * sum(i['missed'] for i in images) / sum(i['n_so'] for i in images):.0f}% of packs)",
                flush=True)


if __name__ == "__main__":
    main()

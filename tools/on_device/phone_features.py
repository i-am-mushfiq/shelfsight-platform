"""Per-box features from the phone pipeline (tools/check_on_device_models.py), for a variant:
  DEMOIRE=1   blur colour noise / pixel grid after the colour stretch (as the server does)
  DET=path    detector ONNX (e.g. a 960 px export)   DETSIZE=960
  PAD=0.05    widen each crop by this share before fingerprinting
Writes JSON: image -> target, boxes [{sim, col, det, bp, bc, area, box, sim2}]."""
import json, math, os, re, sys
from pathlib import Path

import cv2
import numpy as np
import onnxruntime as ort

sys.path.insert(0, "tools")
from check_on_device_models import Pipeline  # noqa: E402
from retail_platform.vision.screen_photo import remove_moire  # noqa: E402

pipe = Pipeline()
if os.environ.get("DET"):
    o = ort.SessionOptions(); o.intra_op_num_threads = 4
    pipe.detector = ort.InferenceSession(os.environ["DET"], o, providers=["CPUExecutionProvider"])
DETSIZE = int(os.environ.get("DETSIZE", "640"))
DEMOIRE = os.environ.get("DEMOIRE") == "1"

import csv
from retail_platform.vision.packshot_matcher import split_packs
from retail_platform.vision.screen_photo import normalise_colours


def degrade(pack, rng, strength):
    """A pack shot as it looks in a phone photo of a screen, after the app's own clean-up."""
    h, w = pack.shape[:2]
    sw = int(rng.uniform(90, 150)); sh = max(8, int(h * sw / w))
    small = cv2.resize(pack, (sw, sh), interpolation=cv2.INTER_AREA)
    grid = cv2.resize(small, (sw * 3, sh * 3), interpolation=cv2.INTER_NEAREST).astype(np.float32)
    mask = np.full((3, 3, 3), 1 - .6 * strength, np.float32)
    for col, ch in enumerate((2, 1, 0)):
        mask[:, col, ch] = 1.0
    grid = np.clip(grid * np.tile(mask, (sh, sw, 1)) * (1 + .5 * strength), 0, 255)
    shot = cv2.resize(grid, (int(sw * rng.uniform(1.1, 1.5)), int(sh * rng.uniform(1.1, 1.5))), interpolation=cv2.INTER_LINEAR)
    shot = shot * (1 + strength * rng.uniform(-.12, .12, 3)) * (1 - .2 * strength) + 25 * strength
    shot = cv2.GaussianBlur(np.clip(shot, 0, 255).astype(np.uint8), (0, 0), .6 + .6 * strength)
    shot = cv2.imdecode(cv2.imencode(".jpg", shot, [cv2.IMWRITE_JPEG_QUALITY, 70])[1], cv2.IMREAD_COLOR)
    shot = remove_moire(normalise_colours(shot)) if DEMOIRE else normalise_colours(shot)
    return cv2.cvtColor(shot, cv2.COLOR_BGR2RGB)


rng = np.random.default_rng(7)
aug_crops, aug_owner = [], []
for row in csv.DictReader(open("datasets/sfbl_catalog/products.csv", encoding="utf-8")):
    files = [f.strip() for f in row["local_images"].split("|") if f.strip() and "_desc" not in f]
    if not files:
        continue
    sku = f"SFBL-{int(row['pid']):03d}"
    index = next(i for i, p in enumerate(pipe.products) if p["sku"] == sku)
    for name in files:
        for crop in split_packs(Path("datasets/sfbl_catalog", name).read_bytes()):
            if min(crop.shape[:2]) >= 16:
                for k in range(2):
                    aug_crops.append(degrade(crop, rng, .5 + .5 * k)); aug_owner.append(index)
aug_emb = np.concatenate([pipe.embedder.run(None, {"pixels": np.stack([pipe.clip_input(c) for c in aug_crops[i:i + 16]])})[0]
                          for i in range(0, len(aug_crops), 16)])
aug_emb /= np.linalg.norm(aug_emb, axis=1, keepdims=True)
aug_owner = np.array(aug_owner)
print("augmented views", len(aug_owner))
PAD = float(os.environ.get("PAD", "0"))


def detect(rgb):
    h, w = rgb.shape[:2]
    scale = DETSIZE / max(h, w)
    nw, nh = round(w * scale), round(h * scale)
    px, py = (DETSIZE - nw) // 2, (DETSIZE - nh) // 2
    canvas = np.full((DETSIZE, DETSIZE, 3), 114, np.uint8)
    canvas[py:py + nh, px:px + nw] = cv2.resize(rgb, (nw, nh), interpolation=cv2.INTER_AREA)
    out = pipe.detector.run(None, {"images": (canvas / 255.0).transpose(2, 0, 1)[None].astype(np.float32)})[0][0]
    boxes = []
    for x0, y0, x1, y1, score, _ in out:
        if score < 0.05:
            continue
        boxes.append([max(0, (x0 - px) / scale), max(0, (y0 - py) / scale), min(w, (x1 - px) / scale),
                      min(h, (y1 - py) / scale), float(score)])
    boxes.sort(key=lambda b: -b[4])
    kept, frame = [], w * h
    for b in boxes:
        area = (b[2] - b[0]) * (b[3] - b[1])
        if not .002 * frame <= area <= .85 * frame or b[2] - b[0] < 8 or b[3] - b[1] < 8:
            continue
        if all((lambda inter, ka: inter / (area + ka - inter) <= .3 and inter / min(area, ka) <= .6)(
                max(0, min(b[2], k[2]) - max(b[0], k[0])) * max(0, min(b[3], k[3]) - max(b[1], k[1])),
                (k[2] - k[0]) * (k[3] - k[1])) for k in kept):
            kept.append(b)
    return kept


out = {}
for label, root in (("clean", Path(sys.argv[1])), ("screen", Path(sys.argv[2]))):
    for f in sorted(q for q in root.rglob("*") if q.suffix in (".png", ".jpg")):
        bgr = cv2.imread(str(f))
        s = min(1.0, 1280 / max(bgr.shape[:2]))
        if s < 1:
            bgr = cv2.resize(bgr, None, fx=s, fy=s, interpolation=cv2.INTER_AREA)
        rgb = pipe.stretch(cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB))
        if DEMOIRE:
            rgb = cv2.cvtColor(remove_moire(cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)), cv2.COLOR_BGR2RGB)
        boxes = detect(rgb)
        h, w = rgb.shape[:2]
        crops = []
        for b in boxes:
            dx, dy = (b[2] - b[0]) * PAD, (b[3] - b[1]) * PAD
            x0, y0, x1, y1 = int(max(0, b[0] - dx)), int(max(0, b[1] - dy)), int(min(w, b[2] + dx)), int(min(h, b[3] + dy))
            crops.append(rgb[y0:max(y1, y0 + 2), x0:max(x1, x0 + 2)])
        rows = []
        if crops:
            def embed(cs):
                f = np.concatenate([pipe.embedder.run(None, {"pixels": np.stack([pipe.clip_input(c) for c in cs[i:i + 16]])})[0]
                                    for i in range(0, len(cs), 16)])
                return f / np.linalg.norm(f, axis=1, keepdims=True)
            feats = embed(crops)
            inner = [c[int(c.shape[0] * .075):max(int(c.shape[0] * .925), int(c.shape[0] * .075) + 2),
                       int(c.shape[1] * .075):max(int(c.shape[1] * .925), int(c.shape[1] * .075) + 2)] for c in crops]
            tta = feats + embed(inner); tta /= np.linalg.norm(tta, axis=1, keepdims=True)
            sims_tta = tta @ pipe.view_emb.T
            sims_aug = feats @ aug_emb.T
            sims_tta_aug = tta @ aug_emb.T
            sims = feats @ pipe.view_emb.T
            logits = 100 * feats @ pipe.brand_emb.T - pipe.brand_bias
            probs = np.exp(logits - logits.max(1, keepdims=True)); probs /= probs.sum(1, keepdims=True)
            for i, b in enumerate(boxes):
                per = {}
                for v, sv in enumerate(sims[i]):
                    p = int(pipe.view_product[v]); per[p] = max(per.get(p, -2), float(sv))
                ranked = sorted(per.items(), key=lambda kv: -kv[1])
                product, sim = ranked[0]
                hist = pipe.colours(crops[i])
                col = max(1 - math.sqrt(max(0, 1 - float(np.sqrt(hist * pipe.view_col[v]).sum())))
                          for v in np.where(pipe.view_product == product)[0])
                best = int(probs[i].argmax())
                brand = pipe.brands[best] if best < len(pipe.brands) else None
                def best_of(row_base, row_aug=None):
                    per2 = {}
                    for v, sv in enumerate(row_base):
                        p2 = int(pipe.view_product[v]); per2[p2] = max(per2.get(p2, -2), float(sv))
                    if row_aug is not None:
                        for v, sv in enumerate(row_aug):
                            p2 = int(aug_owner[v]); per2[p2] = max(per2.get(p2, -2), float(sv))
                    pr, sm = max(per2.items(), key=lambda kv: kv[1])
                    cl = max(1 - math.sqrt(max(0, 1 - float(np.sqrt(hist * pipe.view_col[v]).sum())))
                             for v in np.where(pipe.view_product == pr)[0])
                    return sm, cl
                extra = {}
                extra["sim_tta"], extra["col_tta"] = best_of(sims_tta[i])
                extra["sim_aug"], extra["col_aug"] = best_of(sims[i], sims_aug[i])
                extra["sim_tta_aug"], extra["col_tta_aug"] = best_of(sims_tta[i], sims_tta_aug[i])
                extra["emb"] = [round(float(v), 4) for v in feats[i]]
                rows.append({**extra, "sim": sim, "sim2": ranked[1][1], "col": col, "det": b[4], "bp": float(probs[i, best]),
                             "bc": bool(brand and not pipe.products[pipe.brand_product[brand]]["is_own"]),
                             "box": [b[0] / w, b[1] / h, (b[2] - b[0]) / w, (b[3] - b[1]) / h]})
        out[f"{label}/{f.name}"] = {"target": int(re.search(r"(\d+)pct", f.name).group(1)), "boxes": rows}
Path(sys.argv[3]).write_text(json.dumps(out, default=float))
print("wrote", sys.argv[3], len(out))

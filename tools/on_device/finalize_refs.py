"""Final per-mode thresholds (tuned on all 20 shelves, each shelf looking up only the others) and
the shelf-pack reference set, written into assets/recognition/catalog.json."""
import base64, json, sys
import numpy as np
sys.argv, args = sys.argv[:2], sys.argv[1:]
import gallery_eval as G  # noqa: E402  (reuses prepare/predict/score/grid)

CATALOG = args[0]
modes = {"clean": args[1], "screen": args[2]}
catalog = json.load(open(CATALOG, encoding="utf-8"))
refs, thresholds = {}, {}
for mode, path in modes.items():
    G.data = G.prepare(json.load(open(path)))
    everyone = list(range(20))
    tuned = []
    for i in everyone:
        emb_i, lab_i = G.gallery([j for j in everyone if j != i])
        img = dict(G.data[mode][i]); G.add_gallery_features([img], emb_i, lab_i); tuned.append(img)
    best = max(G.grid("combined", tuned), key=lambda p: (lambda r: r[1] - .5 * r[0])(G.score(tuned, "combined", p)))
    mae, acc = G.score(tuned, "combined", best)
    print(mode, {k: round(float(v), 3) for k, v in best.items()}, f"(on all shelves: share MAE {mae:.1f}, accuracy {acc:.1f}%)")
    emb, lab = G.gallery(everyone)
    refs[mode] = {"embeddings": base64.b64encode(np.ascontiguousarray(emb, np.float16).tobytes()).decode(),
                  "labels": "".join(lab.tolist()), "k": 7}
    thresholds[mode] = {"box": 0.1, "other": round(float(best["D"]), 3), "brand_read": round(float(best["BR"]), 3),
                        "pack_weight": 0.5, "reference_weight": round(float(best["W"]), 3),
                        "accept": round(float(best["T"]), 4), "fragment_vote": round(float(best["PX"]), 3),
                        "demoire": mode == "screen"}
catalog["references"] = refs
catalog["thresholds"] = thresholds
catalog["version"] = 2
json.dump(catalog, open(CATALOG, "w", encoding="utf-8"))
print("references:", {m: len(r["labels"]) for m, r in refs.items()})

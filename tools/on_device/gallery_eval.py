"""Shelf-pack reference set (lookup of labelled packs from OTHER shelves), 2-fold."""
import itertools, json, sys
import numpy as np
sys.argv, args = sys.argv[:2], sys.argv[1:]
from labelled_eval import prepare

data = prepare(json.load(open(args[0]))) if __name__ == "__main__" else None


def gallery(fold):
    """Labelled S/O packs from both sets' images in this fold."""
    embs, labs = [], []
    for label in ("clean", "screen"):
        for i in fold:
            img = data[label][i]
            keep = np.isin(img["truth"], ["S", "O", "X"])
            embs.append(img["emb"][keep]); labs.append(img["truth"][keep])
    return np.concatenate(embs), np.concatenate(labs)


def add_gallery_features(images, emb, lab, k=7):
    s_mask, o_mask, x_mask = lab == "S", lab == "O", lab == "X"
    for img in images:
        if len(img["emb"]) == 0:
            img["gs"] = img["go"] = img["vote"] = img["xvote"] = np.zeros(0); continue
        sims = img["emb"] @ emb.T
        img["gs"] = sims[:, s_mask].max(1); img["go"] = sims[:, o_mask].max(1)
        top = np.argsort(-sims, axis=1)[:, :k]
        w = np.take_along_axis(sims, top, 1)
        packs = (s_mask | o_mask)[top]
        img["xvote"] = (w * x_mask[top]).sum(1) / w.sum(1)
        img["vote"] = (w * s_mask[top]).sum(1) / np.maximum((w * packs).sum(1), 1e-6)


def predict(img, rule, p):
    if len(img["sim"]) == 0:
        return np.zeros(0, bool), np.zeros(0, bool)
    brand = img["bc"] & (img["bp"] >= p["BR"])
    if rule == "vote":
        own = ~brand & (img["vote"] >= p["T"])
    elif rule == "veto":
        own = ~brand & (img["sim"] + .5 * img["col"] >= p["T"]) & (img["go"] - img["gs"] < p["M"])
    else:  # combined
        own = ~brand & (img["sim"] + .5 * img["col"] + p["W"] * (img["gs"] - img["go"]) >= p["T"])
    fragment = img["xvote"] >= p.get("PX", 1.01)
    own &= ~fragment
    other = (brand | (~own & (img["det"] >= p["D"]))) & ~fragment
    return own, other


def score(images, rule, p):
    errs, correct, total = [], 0, 0
    for img in images:
        own, other = predict(img, rule, p)
        n = own.sum() + other.sum()
        errs.append(abs(100 * own.sum() / max(1, n) - img["true_share"]))
        so = np.isin(img["truth"], ["S", "O"])
        correct += int(((img["truth"] == "S") & own)[so].sum() + ((img["truth"] == "O") & ~own)[so].sum())
        total += img["n_so"]
    return float(np.mean(errs)), 100 * correct / total


def grid(rule, images):
    base = dict(BR=.95, D=.2, M=0, W=0, T=0)
    if rule == "vote":
        space = itertools.product(np.linspace(.2, .8, 25), (.85, .95, 1.01), (.1, .2, .3), (.4, .5, .6, 1.01))
        for T, BR, D, PX in space: yield {**base, "T": T, "BR": BR, "D": D, "PX": PX}
    elif rule == "veto":
        vals = np.concatenate([i["sim"] + .5 * i["col"] for i in images if len(i["sim"])])
        for T, M, BR, D, PX in itertools.product(np.linspace(*np.percentile(vals, (5, 95)), 20), (-.02, 0, .02, .05, 1), (.85, .95, 1.01), (.1, .2, .3), (.5, 1.01)):
            yield {**base, "T": T, "M": M, "BR": BR, "D": D, "PX": PX}
    else:
        for W in tuple(float(w) for w in __import__("os").environ.get("WS", ".5,1,2,4").split(",")):
            vals = np.concatenate([i["sim"] + .5 * i["col"] + W * (i["gs"] - i["go"]) for i in images if len(i["sim"])])
            for T, BR, D, PX in itertools.product(np.linspace(*np.percentile(vals, (5, 95)), 20), (.85, .95, 1.01), (.1, .2, .3), (.4, .5, .6, 1.01)):
                yield {**base, "W": W, "T": T, "BR": BR, "D": D, "PX": PX}


if __name__ == "__main__":
    A, B = list(range(20))[0::2], list(range(20))[1::2]
    for label in ("clean", "screen"):
        for rule in __import__("os").environ.get("RULES", "vote,veto,combined").split(","):
            results = []
            for test, ref in ((B, A), (A, B)):
                # Tuning sees only the reference half: each of its shelves looks up the OTHER reference shelves.
                tr = []
                for i in ref:
                    emb_i, lab_i = gallery([j for j in ref if j != i])
                    img = dict(data[label][i]); add_gallery_features([img], emb_i, lab_i); tr.append(img)
                best = max(grid(rule, tr), key=lambda p: (lambda r: r[1] - .5 * r[0])(score(tr, rule, p)))
                emb, lab = gallery(ref)
                te = [dict(data[label][i]) for i in test]
                add_gallery_features(te, emb, lab)
                results.append((score(te, rule, best), len(te)))
            mae = sum(r[0] * n for r, n in results) / 20
            acc = sum(r[1] * n for r, n in results) / 20
            print(f"{label:6} {rule:9} CV share MAE {mae:5.1f}  CV pack accuracy {acc:5.1f}%", flush=True)

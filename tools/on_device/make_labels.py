import json, re, sys
from collections import Counter
S = sys.argv[1]
def exp(s):
    out = []
    for tok in s.split():
        m = re.fullmatch(r"([SOX])\*(\d+)", tok)
        out += [m.group(1)] * int(m.group(2)) if m else [tok]
    return out
sheets = [
 "S S O O O O O O O O O O O O O O O S O X X X O O O O O O O O O O O O O O O X X X X O O O X X X S",
 "X X O X X X X X X X O X X X X X X X O O O O O O S S O S O O O O S O S X X X X X X X S O O O O O",
 "O S O O S O O O O O O X X O X O X O X*13 O O S O*10 X O O O",
 "O O X X X X X O O O O O O O O O O O O O O S S O O O O O O S O O O O O O X X X X X X X X X O O S",
 "O S O O O O O O O O S O O O S O O O O O O O O O O O O O S O O X X X X S S O O O O O O O O S O O",
 "O O X O X*27 S S S S S O S S S O S S S O S S S",
 "S S S S S S S O S S O S S S O S X*7 S S S S S O S O S S S S O S O S S S S O S S S O X",
 "X*14 S S O S S S O S O O S O O O S S O S O S O S S S S S O X*6 S",
 "X X S X X X X S X O O O O O O S O O S O S S O O O O S O O S S O O O S S O S O O O X X X O X O O",
 "O S O O S S O O S O O O O O O S O O O O O O O O O O O O O X*12 S S S S O O O",
 "S S S O S S S S O S O O S O S O O O O S O O O O S S S X*10 S S S S S S S O S S S",
 "S S O S S S S S O S S S S S S S O S O S O X X X O S O O S S O S S S S S O O S S S S O S S S S S",
 "O S S S O S S O O X S O S S S S O S S X O X S X O O X X S X X X S S S S S S S O O S O S S S S S",
 "S O S O O S S S O O O O O O O S O O X*6 O O O O S S O S O O S O S S O S O S O O S S O S",
 "S O O S O O O O X X X O S O*8 S O*4 S O*3 S O O S O*10 S S O O",
 "S O S S O S S O S S S S S S S O O S O S S O S O S O S S S O S S X S X*8",
]
labels = []
for i, sh in enumerate(sheets):
    t = exp(sh); expected = 48 if i < 15 else 42
    assert len(t) == expected, (i, len(t))
    labels += t
boxes = json.load(open(f"{S}/label/boxes.json"))
assert len(labels) == sum(len(v) for v in boxes.values())
out, k = {}, 0
for name, bs in boxes.items():
    out[name] = [{"box": b[:4], "label": labels[k + j]} for j, b in enumerate(bs)]; k += len(bs)
json.dump(out, open(f"{S}/label/labels.json", "w"))
print(Counter(labels))
for name, bs in out.items():
    s = sum(b["label"] == "S" for b in bs); o = sum(b["label"] == "O" for b in bs)
    print(f"{name:52} true {100*s/max(1,s+o):5.1f}%  intended {int(re.search(r'(\d+)pct', name).group(1)):3d}%  S {s:2d} O {o:2d}")

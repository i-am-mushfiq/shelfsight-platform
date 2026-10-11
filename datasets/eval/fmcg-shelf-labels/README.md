# FMCG shelf labels (on-device recogniser)

Hand labels for every product box the on-device detector (SKU-110K YOLO11n) finds on the 20
AI-generated demo shelves in `FMCG_Shelf_Test_Set_20`: `S` Square product, `O` other brand,
`X` not a whole pack (fragment, background, unreadable sliver). 762 boxes: 240 S, 334 O, 188 X.

* `labels_clean.json` — boxes (normalised x, y, w, h) per image, as detected on the clean image.
* `labels_screen.json` — the same packs mapped into the simulated phone photos of those shelves on
  a monitor (`retail_platform/tests/screen_sim.py`, seed = image index, CRT every third image).

Labelled by reading each crop's brand mark (Radhuni, Ruchi, Chopstick, Aaram = Square). Used to
measure the recogniser (2-fold cross-validation by shelf) and as the shelf-pack reference set
bundled in `assets/recognition/catalog.json`. The demo shelves themselves are therefore known to
the app; only held-out (cross-validated) numbers describe performance on new shelves.

# Evaluation datasets

Every vision model version must be evaluated on a **frozen holdout** before it is activated
(`python -m retail_platform.cli evaluate --manifest <path> --record`).

| Dataset | Purpose | Status |
|---|---|---|
| `smoke-v0` | Regression smoke test on two AI-generated images (count-level truth) | available |
| `holdout-v1` | Field photos, box-level labels with SKU ids, stratified by channel, lighting, device and category | **to be built** from the first field captures; freeze before any training |

Rules for the holdout:
* Frozen before training; its sha256 is recorded on every evaluation run.
* Never used for training or prompt tuning.
* Stratified so per-slice metrics are meaningful (≥30 images per channel slice).
* Commercially important SKUs listed explicitly with their own acceptance thresholds.

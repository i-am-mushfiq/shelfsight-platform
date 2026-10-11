# ShelfSight

ShelfSight is a retail intelligence platform for FMCG field sales: a Flutter app
for Sales Officers and managers on top of a FastAPI backend that holds the
outlet, product, order and shelf-audit data and turns it into evidence-backed
recommendations.

Architecture, domain model, milestones and current status are in
[docs/architecture.md](docs/architecture.md). Read the status section there
before trusting any number the system shows: all demo data is synthetic, and
without an Anthropic API key the vision model is a logo-only placeholder.

## The field visit

1. **Pick the shop**, or register a new one in the field (it starts unverified and
   is assigned to the officer; shops within 50 m are flagged as possible duplicates).
2. **Say what kind of store it is** from the configured store types (six in the demo:
   Grocery, Cosmetics & Toiletries, Departmental Store, Super Shop, Pharmacy,
   Wholesale). If it differs from the record, the shop's type is updated and audited,
   and that type's rules, targets and restock depth apply.
3. **Photograph the racks.** Each photo may name its rack (category) or be a mixed rack.
   Photos queue offline and upload when there is a connection.
4. **Detection**: own (Square) and competitor products, by SKU where possible. Uncertain
   boxes go to the officer for a one-tap review.
5. **Submit**: the visit report (share of shelf by company, brand, SKU and rack;
   must-stock availability; placement; actions) and, unless configured otherwise,
   an **automatic order** for what the shelf and the order history call for. The
   officer can edit, confirm or cancel it for 24 hours; the original suggestion is
   kept next to the final quantities.

The automatic order only contains usual order sizes, gaps on shelves that were
photographed *and* identified at SKU level, and recommendations the officer accepted.
A logo-only model never marks products as missing, so it cannot trigger restocking.

## Repository layout

```text
retail_platform/        Platform API, domain logic, vision pipeline, migrations, tests
ai_service/             OpenCV facing + logo engine (used by the platform) and legacy v1 API
lib/                    Flutter application
datasets/eval/          Model evaluation manifests
scripts/e2e_smoke.py    End-to-end smoke test against a running server
docs/                   Architecture and progress notes
render.yaml             Render Blueprint (platform + PostgreSQL; not yet deployed)
```

## Run the backend locally

Requires [uv](https://docs.astral.sh/uv/). Python 3.12 is installed by uv.

```powershell
uv sync --extra llm
uv run python -m retail_platform.cli seed          # migrate + load the SYNTHETIC demo organization
uv run uvicorn retail_platform.main:app --host 0.0.0.0 --port 8000
```

API documentation: `http://127.0.0.1:8000/docs`. Metrics: `/metrics`.

The seed command prints the demo employee ids. They all share the password
`shelf123` and exist only in the synthetic organization:

| Employee id | Role | Sees |
|---|---|---|
| `SO-1001` | Sales Officer | assigned outlets in Banani–Gulshan |
| `TO-2001` | Supervisor | Dhaka North (two territories) |
| `BM-3001` | Brand manager | whole organization, can edit rules |
| `MG-4001` | Management | whole organization, read only |
| `AD-0001` | Admin | everything, including data import |

Useful commands:

```powershell
uv run python -m retail_platform.cli seed --reset     # rebuild the synthetic organization
uv run python -m retail_platform.cli demo-audit       # run one shelf audit from test_assets
uv run python -m retail_platform.cli evaluate --record  # evaluate the vision model, store the run
uv run python -m retail_platform.cli import-pack-shots --dir path\to\packshots  # files named by SKU
uv run python -m retail_platform.cli export-training --out var\training     # reviewed photos -> YOLO + SKU crops
uv run python scripts/e2e_smoke.py http://127.0.0.1:8000
```

Pack shots: name each file after its SKU (`SQ-MER-SOAP-100.jpg`, or
`SQ-MER-SOAP-100__back.png` for another view). They are sent with each recognition
request so the model can compare packaging; admins can also upload them through
`POST /v2/admin/products/{id}/reference-images`.

Training export: only photos whose every detection a person reviewed are exported,
and any image that appears in an evaluation manifest under `datasets/eval` is
skipped, so the holdout never leaks into training.

On Windows machines where Application Control blocks the `pytest.exe` launcher,
run tests through the interpreter:

```powershell
.venv\Scripts\python.exe -m pytest
```

### Configuration

| Variable | Default | Purpose |
|---|---|---|
| `SHELFSIGHT_DATABASE_URL` | SQLite file under `var/` | Use `postgresql://…` in production |
| `SHELFSIGHT_JWT_SECRET` | random per process in development | Required when `SHELFSIGHT_ENV=production` |
| `SHELFSIGHT_BLOB_DIR` | `var/blobs` | Where shelf photos are stored |
| `SHELFSIGHT_VISION_PROVIDER` | `auto` | `auto` = `visual-lookup` when PyTorch is installed, else `packshot-match` (neither calls an external service; `SHELFSIGHT_VISUAL_LOOKUP=0` forces the latter). `claude-shelf` / `claude-crop` call the Anthropic API and are used only when set by name |
| `ANTHROPIC_API_KEY` | unset | Needed only for `claude-shelf` / `claude-crop` |
| `SHELFSIGHT_RECOGNIZER_MODEL` | `claude-opus-5-5` | Model used by `claude-shelf` and `claude-crop` |
| `SHELFSIGHT_RECOGNIZER_EFFORT` | `medium` | Reasoning effort for `claude-shelf` |
| `SHELFSIGHT_RECOGNIZER_IMAGE_SIDE` | `1600` | Longest side (px) of the photo sent for recognition |
| `SHELFSIGHT_MAX_REFERENCE_IMAGES` | `24` | Catalogue pack shots sent per request (0 disables) |
| `SHELFSIGHT_REVIEW_THRESHOLD` | `0.75` | Detections below this confidence are sent to human review |
| `SHELFSIGHT_SCREEN_PHOTOS` | `auto` | Photos taken of a screen: `auto` detects them, `always` / `never` force it |
| `SHELFSIGHT_AUTO_ORDER` | `confirm` | On visit submit: `confirm` places the shelf-driven order, `draft` leaves it for the officer, `off` creates none |
| `SHELFSIGHT_RUN_WORKER` | `1` | Run the background job worker inside the API process |

## Run the Flutter app

The API URL is a compile-time define. For a phone connected over USB with the
backend on this machine (debug builds allow plain HTTP; release builds do not):

```powershell
adb reverse tcp:8000 tcp:8000
flutter run --dart-define=SHELFSIGHT_API_URL=http://127.0.0.1:8000
```

Against a deployed HTTPS backend:

```powershell
flutter build apk --release --dart-define=SHELFSIGHT_API_URL=https://YOUR-SERVICE.onrender.com
```

```powershell
flutter analyze
flutter test
```

## Deploy

`render.yaml` describes the platform web service and a PostgreSQL database. It
has been updated for the platform but **has not been deployed or verified**. The
free plan's disk is ephemeral, so shelf photos would be lost on restart: move
blob storage to an S3-compatible store before any field use.

The legacy `/v1/analyze` and `/artifacts/*` endpoints are still served by the
platform so previously distributed builds of the app keep working.

## Demo: live Square Food recognition and 360° spheres

No training and no AI service: everything is looked up against the scraped Square Food &
Beverage pack shots in `datasets/sfbl_catalog`. `seed` imports the catalogue automatically when
that folder exists (`import-sfbl-catalog` does it alone), together with the competitor brands that
appear on the demo shelf images (ShadBari, Jhalika, Bhojona, Moyna Bite, NoboTaste, Mawa, ...).

Two recognisers, chosen automatically (`SHELFSIGHT_VISION_PROVIDER=auto`):

* **`visual-lookup`** (used when PyTorch is installed; built for AI-generated demo shelves):
  OWLv2 finds every pack, CLIP names it by its look against the pack shots (plus a colour check),
  and CLIP reads competitor brand names printed in English on the pack. Runs on the laptop GPU.
  Install once (about 3 GB, plus 2 GB of models downloaded on first start):
  ```powershell
  uv pip install --python .venv\Scripts\python.exe torch torchvision --index-url https://download.pytorch.org/whl/cu128
  uv pip install --python .venv\Scripts\python.exe "transformers>=4.50,<5" pillow scipy
  ```
* **`packshot-match`** (fallback without PyTorch): exact SIFT matching, which needs the real
  printed artwork; it also runs inside `visual-lookup` and wins where it finds an exact match.

1. Run the backend on the laptop, reachable from the phone on the same network:
   ```powershell
   uv run python -m retail_platform.cli seed --reset
   uv run uvicorn retail_platform.main:app --host 0.0.0.0 --port 8000
   ```
   Allow port 8000 through Windows Firewall, and find the laptop's IP with `ipconfig`.
2. Install the app. The server address can be changed on the sign-in screen
   ("Server: ... · Change" → Test → Save), so the APK need not be rebuilt for another laptop.
3. Sign in as `SO-1001` / `shelf123`, open a shop, start the audit, choose the store type.
   On the camera screen:
   * **Live scan**: frames are looked up several times a second; each pack is outlined (green =
     Square, red = competitor or not ours) with its name and confidence, and listed below.
   * **360° sphere**: tap Start and turn slowly on the spot; a photo is taken every 30°
     (gyroscope-guided). The server stitches them, recognises products in the panorama,
     and the 360° viewer shows them pinned where they are.

**Photographing a screen** (the demo shelves shown on a monitor or CRT) works: each photo is
colour-corrected and smoothed against moire, and a photo recognised as being of a screen (by
the monitor's outline or its pixel-grid pattern) is judged with thresholds suited to it. Set
`SHELFSIGHT_SCREEN_PHOTOS=always` if every photo will be of a screen (detection can miss a screen
that fills the whole frame), `never` for real shelves only. Tips: fill most of the frame with
the screen, hold the phone square to it, turn the screen brightness up and room lights down to
avoid glare, and step back slightly if coloured wave bands (moire) show in the viewfinder.

Measured on the 20 AI-generated shelves in `FMCG_Shelf_Test_Set_20` (RTX 4070 SUPER), as the
share of Square packs against the share each image was made with: 6.6 points off on average
shown directly, and 10.7 on simulated phone photos of the same images on an LCD or CRT
(`retail_platform/tests/screen_sim.py`); about 0.3 s per image. Close variants of one design
(Chicken vs Fish Curry Masala) are often confused, and a competitor pack drawn like a Square pack
without a readable English brand name can pass as Square. The thresholds were tuned on these
images and the screen photos are simulated, so treat the numbers as a demo setting, not a field
accuracy; real phone photos of a screen have not been measured yet.

## Vision model status

Four recognisers ship. **`visual-lookup`** and **`packshot-match`** (described above) need no
training and no external service. The other two:

* **`claude-shelf`** (only when `SHELFSIGHT_VISION_PROVIDER=claude-shelf` and an API key are set): one Claude request per
  photo with the closed catalogue of own and competitor SKUs and any pack shots. It
  returns every run of identical facings with a box and a catalogue product id or
  "unknown"; answers outside the catalogue are rejected, and uncertain ones go to
  human review. If the API is unreachable, refuses, or returns unusable output, the
  photo falls back to the OpenCV baseline with a warning. **It has only been tested
  against a fake client; accuracy on real Bangladeshi shelves has not been measured.**
  Run `evaluate --record` on a labelled holdout before relying on it.
* **`opencv-baseline`**: an OpenCV contour detector plus a Square-logo classifier
  trained on synthetic augmentations of one logo. On the two-image smoke set in
  `datasets/eval/smoke-v0` it finds 6 and 2 of 12 facings and cannot name SKUs or
  competitor brands. It keeps the capture → review → measurement loop running
  without an API key; it is not a field-accuracy model.

See [ai_service/README.md](ai_service/README.md) for training a detector from the
`export-training` output once labelled field photos exist, and
`datasets/eval/README.md` for the holdout rules.

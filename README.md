# ShelfSight

ShelfSight is a retail intelligence platform for FMCG field sales: a Flutter app
for Sales Officers and managers on top of a FastAPI backend that holds the
outlet, product, order and shelf-audit data and turns it into evidence-backed
recommendations.

Architecture, domain model, milestones and current status are in
[docs/architecture.md](docs/architecture.md). Read the status section there
before trusting any number the system shows: all demo data is synthetic and the
bundled vision model is a placeholder.

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
uv run python scripts/e2e_smoke.py http://127.0.0.1:8000
```

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
| `SHELFSIGHT_VISION_PROVIDER` | `opencv-baseline` | `claude-crop` adds SKU recognition (needs Anthropic credentials) |
| `SHELFSIGHT_RECOGNIZER_MODEL` | `claude-opus-5-5` | Model used by `claude-crop` |
| `SHELFSIGHT_REVIEW_THRESHOLD` | `0.75` | Detections below this confidence are sent to human review |
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

## Vision model status

The bundled model is an OpenCV contour detector plus a Square-logo classifier
trained on synthetic augmentations of one logo. On the two-image smoke set in
`datasets/eval/smoke-v0` it finds 6 and 2 of 12 facings. It exists so the
capture → review → measurement loop can run; it is not a field-accuracy model.
See [ai_service/README.md](ai_service/README.md) for training the detectors once
labelled field photos exist, and `datasets/eval/README.md` for the holdout rules.

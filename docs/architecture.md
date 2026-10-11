# ShelfSight Retail Intelligence Platform — Architecture

Status: living document. Owner: platform engineering. Last revised 2026-10-07.

This document answers, in order: where the code is today, where it is going,
the domain model that holds it together, how we get real data, how AI is used,
what ships by 11 October 2026, and which decisions carry the most risk.

---

## 1. Current-state assessment

The repository contains two applications that share no data.

| Component | What exists | Assessment |
|---|---|---|
| `ai_service/` (FastAPI, OpenCV) | `POST /v1/analyze` takes photos and returns boxes labelled `square` / `other` / `uncertain`, a facing share, and annotated JPEGs. | Stateless. Nothing is persisted: no outlet, visit, image record, model version or correction. The facing detector is a contour heuristic; the only trained model is a HOG/colour logo classifier trained on synthetic augmentations of one logo. It cannot identify a SKU, a brand other than "Square", or a competitor. Accuracy on field photos has never been measured. |
| `lib/` (Flutter) | Login, territory map, store check-in, camera/gallery capture, review, result, "detection review", audit history, territory dashboard, competitor alerts, audio "Learn" screen. | A polished shell over hardcoded data. Users, shops, audits, territory shares and competitor alerts are constants in `session.dart` and the screens. The detection-review screen is not wired to the analysis result, so corrections are discarded. "Audio coaching" is a timer. |
| Deployment | `render.yaml` deploys `ai_service` to a free Render instance with `/tmp` storage. | Fine for a demo; not a production environment (ephemeral disk, cold starts, no database). |

What is worth keeping:

* The capture → review → analyse → result UX and the visual design.
* The `ProductDetector` / logo-matcher protocol boundary in `ai_service/detectors.py`
  — it already anticipates swapping the heuristic for trained weights.
* The image-quality checks (blur, brightness, resolution).
* The YOLO dataset/training scaffolding under `ai_service/training`.

What must change:

* There is no system of record. Every capability in the assignment (portfolio
  ratio, competitor analysis, channel placement, retail classification, sales
  coaching) is a question about outlets, products and history. None of that is
  modelled.
* "Competitor" is a UI label. It needs to be a first-class part of the catalogue.
* Vision results must be stored as versioned, reviewable evidence, not returned
  and forgotten.

## 2. Target architecture

A **modular monolith** with one relational database, plus an AI subsystem behind
explicit provider interfaces. No microservices, no Kubernetes: the team is small,
the load is modest (hundreds of field users, thousands of images per day), and
the hard problems are data quality and model quality, not horizontal scale.

```
 Flutter field app (offline queue)      Web/Flutter dashboards
          │  HTTPS + JWT                        │
          ▼                                     ▼
 ┌─────────────────────────── API layer (FastAPI) ───────────────────────────┐
 │ auth · catalog · outlets · visits/captures · analytics · recommendations │
 │ orders · admin/config · ml-registry · call-prep                            │
 └───────────────┬───────────────────────────────────────────┬───────────────┘
                 ▼                                           ▼
 ┌──────── Domain services (pure, tested) ───────┐   ┌──── AI orchestration ────┐
 │ portfolio · competitor · placement           │   │ job queue (DB-backed)    │
 │ classification · scoring · recommendations   │◄──┤ vision providers         │
 │ order suggestion · call preparation          │   │  - opencv baseline       │
 └───────────────┬───────────────────────────────┘   │  - multimodal LLM (crop  │
                 ▼                                   │    → catalogue SKU)      │
 ┌──────── Data layer ───────────────────────────┐   │  - trained YOLO (later)  │
 │ PostgreSQL (SQLite for dev/tests)            │   │ model registry           │
 │ Alembic migrations · blob store (images)     │◄──┤ inference log            │
 └───────────────────────────────────────────────┘   │ evaluation harness       │
                                                     └──────────────────────────┘
```

Boundaries that are enforced in code:

* **Domain services never import FastAPI** and never call an AI provider. They
  take data and return results with evidence, so they are unit-testable and
  reusable from the API, batch jobs and evaluation scripts.
* **AI providers are behind interfaces** (`VisionProvider`). The orchestration
  layer records every inference (provider, model version, config, latency, cost,
  input hash, output) before any business logic reads it. The Flutter client
  never talks to an AI provider.
* **Business rules live in data**, not prompts and not CV code: portfolio
  targets, core assortments, placement rules, classification criteria and
  confidence thresholds are rows that admins edit, with versions.

Package layout:

```
retail_platform/
  api/            HTTP routers (auth, catalog, outlets, visits, analytics, admin)
  domain/         pure calculations: portfolio, competitor, placement, shelf,
                  classification, scoring, recommendations, orders, call_prep
  services/       loaders (DB rows → domain records) and intelligence orchestration
  models/         SQLAlchemy ORM (one module per bounded context)
  vision/         provider interface, providers, capture pipeline, model registry
  seed/           isolated synthetic dataset generator
  migrations/     Alembic
  tests/
  jobs.py         durable DB-backed job queue and worker
  storage.py      blob store abstraction (local disk now, S3-compatible later)
  security.py     password hashing, JWT, RBAC, data scoping
  observability.py structured logs, request ids, Prometheus metrics
  evaluation.py   model evaluation against versioned dataset manifests
  cli.py          migrate, seed, classify, refresh, worker, demo-audit, evaluate
ai_service/       existing CV library (consumed by vision/opencv_baseline) + legacy v1 API
datasets/eval/    evaluation manifests
lib/              Flutter field app
scripts/          end-to-end smoke test
```

## 3. Core domain model

Every table carries `organization_id` (tenant / business-unit isolation) and
every business table carries `data_origin` (`production` | `synthetic`). The
synthetic demo lives in its own organization, so it cannot leak into production
reporting even if the flag were ignored.

### Catalogue (own and competitor products in one normalised structure)

```
Manufacturer (is_own)          Square Toiletries = own; Unilever, Reckitt … = competitor
  └─ Brand                     Meril, Lux, Dettol …
       └─ SubBrand             optional
Category (tree)                Personal Care › Skin Cleansing › Bar Soap
Product (= SKU)                brand, category, pack size + unit, price tier,
                               barcode/GTIN, attributes (JSON), launch/discontinue
  ├─ ProductPrice              effective-dated list price / MRP
  ├─ PackagingVersion          artwork generations (drives CV retraining)
  └─ ReferenceImage            catalogue images for recognition
```

Competitor products are rows in the same `product` table, owned by a
manufacturer with `is_own = false`. This is the decision that makes
own-vs-competitor comparison a query rather than a special case: segments,
pack-size bands and price tiers are directly comparable.

### Outlet universe

```
Territory (tree: region › area › territory)
Distributor ── serves ── Territory
Channel (configurable tree)            General Trade › Grocery; Modern Trade › Super Shop; Pharmacy …
Outlet                                 owner, address, GPS, territory, distributor, channel, size indicators
OutletAssignment                       sales officer ↔ outlet (effective-dated)
ClassScheme → OutletClass              e.g. "Outlet Potential v1": A/B/C/D with criteria (data)
OutletClassification                   outlet, class, source (rule|model|human), confidence,
                                       evidence (JSON), scheme version, effective_from/to
```

Classification is a history of assessments, not a column. A human override is
just another row with `source = human`; the effective class prefers the most
recent human assessment, otherwise the most recent rule/model one.

### Commercial history

```
Order (outlet, officer, distributor, date, source: ingest|app)
  └─ OrderItem (product, qty, unit price, value, suggested_qty, recommendation_id)
Promotion → PromotionProduct (eligibility by channel/class, dates)
```

Company order data contains **only own products**. Competitor sell-through is
not knowable from it. Competitor intelligence therefore comes from observations
(shelf audits, manual notes) and, if purchased, retail panel data. The model
keeps these sources separate.

### Rules and targets (versioned configuration)

```
RuleSet (kind, version, status: draft|active|retired, effective dates)
  ├─ PortfolioTarget      scope (channel / outlet class) × dimension (brand / category /
  │                        price tier / pack band) → target share, tolerance
  ├─ CoreAssortment       scope → required product, min facings
  └─ PlacementRule        channel × category/product → expected shelf level, min facings,
                           priority, promotional requirement
```

Analyses record the rule-set version they used, so a result from rules v3 stays
distinguishable from one from rules v4.

### Field execution and visual evidence

```
Visit (outlet, officer, started/ended, GPS, status)
  └─ ShelfCapture (client_capture_id [idempotency], sha256 [dedupe], area/shelf label,
                   blob key, quality result, captured_at, uploaded_at)
       └─ Inference (model_version, config, status, latency_ms, cost, error)
            └─ DetectedObject (bbox, predicted_product_id, predicted_manufacturer_id,
                               label own|competitor|unknown, confidence, shelf_row,
                               verification: unverified|confirmed|corrected|rejected)
                 └─ RecognitionCorrection (original prediction, corrected product/label,
                                           user, reason, model_version, timestamp)
ShelfMeasurement     metric (share_of_shelf | share_of_assortment | facings | presence),
                     scope (manufacturer/brand/category/product), numerator, denominator,
                     basis (all|verified), source inference ids
CompetitorObservation  manual or visual: product/brand, price seen, promo, display, notes
```

Metrics are deliberately distinct types:

| Metric | Definition | Source |
|---|---|---|
| Share of shelf | own facings ÷ all facings in scope | vision + verification |
| Share of assortment | distinct own SKUs present ÷ distinct SKUs present | vision / observation |
| Share of sales (own portfolio mix) | value of a brand/SKU ÷ value of own orders | orders |
| Share of visibility | weighted by position/display (future) | vision + placement |

### Intelligence outputs

```
OutletScore           one row per dimension (assortment, availability, share_of_shelf,
                       placement, competitor_pressure, opportunity) with inputs & version
Recommendation        outlet, type, product, action text, reason, evidence (JSON),
                       expected impact, confidence, priority, generator + version, status
RecommendationFeedback accepted | modified | rejected, by whom, note
```

### AI platform

```
Model → ModelVersion (provider, artifact uri/hash, config, metrics, status)
Inference (above) · EvaluationRun (dataset, model version, per-class metrics)
```

### Platform

`Organization`, `User`, `Role` (sales_officer, supervisor, brand_manager,
management, admin), `AuditLog` (actor, action, entity, before/after, request id).

## 4. Data acquisition plan

Real company data does not exist in this repository. The platform cannot become
useful without it, so obtaining it is a deliverable of the first update.

| Data | Owner at Square (to confirm) | Format we accept | Needed for |
|---|---|---|---|
| SKU master: brand, category, pack, MRP, trade price, barcode, launch/discontinue | Sales Ops / Brand team | CSV/XLSX export from ERP/DMS | everything |
| Competitor SKU list for the target categories | Brand / market research | CSV, or built up from field observations | competitor analysis, CV labels |
| Outlet master: name, GPS, territory, distributor, channel | Sales Ops / DMS | CSV | outlet universe |
| Channel and outlet-class definitions currently used | Sales leadership | document → config rows | channel rules, classification |
| 6–12 months of secondary sales (distributor → outlet) at SKU level | DMS / distributors | CSV | portfolio ratio, peer benchmarks |
| Core assortment / must-stock lists by channel | Trade marketing | CSV | gaps, compliance |
| Planogram / placement guidelines | Trade marketing | PDF → config rows | placement rules |
| Promotions and trade offers | Trade marketing | CSV | call prep, order suggestion |
| Pack shots for every own SKU (current + previous artwork) | Brand team | images | CV reference set |
| Field shelf photos | captured through the app | images + corrections | CV training/eval |
| Current sales-call process, recorded calls (with consent) | Sales training | audio + consent forms | voice phase |

Ingestion is via validated CSV import endpoints and a CLI that reports every
rejected row; nothing is silently coerced. Until real data arrives, a
deterministic synthetic dataset (Section 7) exercises every code path.

Image data strategy: every capture becomes candidate training data. Human
corrections are labels. A fixed, stratified holdout (by channel, lighting,
device, category) is frozen before any model is trained and never used for
training.

## 5. AI/ML strategy

Each technique is used for what it is good at:

| Task | Technique | Phase |
|---|---|---|
| Portfolio mix, gaps, benchmarks, classification, scoring | Deterministic analytics + configurable rules | now |
| Image quality | Classical CV (blur, exposure, resolution, duplicate hash) | now |
| Facing detection | Existing OpenCV baseline → trained detector (YOLO) once ~300 labelled field photos exist | now → M5 |
| SKU recognition | Multimodal LLM classifies each detected crop against a **closed list** of catalogue SKUs (structured output, abstain allowed) → later an embedding/fine-tuned recogniser trained on corrections | M4 → M5 |
| Price tags / pack text | OCR (provider TBD; benchmark) | M4+ |
| Recommendations | Rule-based generators with evidence, ranked; ML ranking once outcome data exists | now → M10 |
| Sales-call analysis | STT (Bangla + code-switching: benchmark candidates on real calls) → event extraction → LLM coaching over structured evidence | M9 |

Principles:

* **No silent certainty.** Every detection carries confidence, model version and
  verification state. Below a configurable threshold the app asks the officer to
  verify. Metrics are reported on `all` and `verified` bases.
* **Closed-set recognition.** The LLM may only answer with a catalogue product id
  or "unknown"; free-text product names are rejected. This prevents invented SKUs.
* **Evaluation before release.** A model version can only be activated after an
  evaluation run on the frozen holdout, reporting per-SKU precision/recall, the
  confusion matrix and calibration, sliced by channel, lighting and device.
  Aggregate accuracy alone is never an acceptance criterion; the commercially
  important SKUs have their own thresholds.
* **Providers are replaceable.** Swapping an LLM vendor or a CV model is a
  provider class plus a model-version row, not a schema or API change.

About the "3-dimensional picture" requirement: the lowest-risk interpretation is
*spatial understanding of a shelf* — which products are where, on which shelf
level, next to what, with how many facings — from ordinary photos, plus
multi-photo coverage of a bay. That directly serves placement, share of shelf
and availability. True 3D reconstruction is costly on low-end phones and adds no
measurable decision value yet; it stays out of scope until a concrete business
question requires it. **This interpretation must be confirmed with Square.**

## 6. Milestones through 11 October 2026

Today is 7 October. Four working days. The goal is a credible vertical slice on
the real architecture, not the whole platform.

| Day | Deliverable |
|---|---|
| 7 Oct | Architecture (this doc). Backend skeleton: schema, migrations, auth/RBAC, audit log, observability. Catalogue + outlet + channel + rules models. Synthetic dataset. |
| 8 Oct | Portfolio intelligence (current vs target vs channel vs peer, gaps), own-vs-competitor analysis, rule-based classification with evidence, outlet scores, recommendations with evidence + feedback. Tests. |
| 9 Oct | Capture pipeline: visit, idempotent upload, quality, inference job queue, vision provider wrapping the existing engine, detections persisted with model version, corrections, share-of-shelf, placement compliance. |
| 10 Oct | Flutter: real login, outlet list, outlet intelligence, recommendations with evidence, capture → upload queue → review/correct → submit. Supervisor dashboard on real API. |
| 11 Oct | Hardening, demo script, progress update to Square including the data request list and open questions. |

### Status on 8 October 2026

Built and covered by automated tests (56 backend, 3 app):

* Schema (40 tables, Alembic migration), auth, role permissions, outlet scoping,
  tenant isolation, audit log, request ids, Prometheus metrics.
* Catalogue with own and competitor products, channels, territories, versioned rules,
  CSV order import with per-row rejection report.
* Portfolio intelligence, rule-based classification with evidence and human override,
  outlet scores, recommendations with evidence, feedback and rejection cooldown,
  suggested order, order capture linked to recommendations, pre-call brief.
* Capture pipeline: idempotent upload, duplicate detection, quality checks, job queue,
  versioned inference, detections with shelf rows, human review stored as corrections,
  share of shelf (all / verified, with uncertainty range), placement compliance.
* Persona analytics: overview, brands, competition, recommendation funnel, AI quality.
* Evaluation harness and a recorded baseline run.
* Field app wired to the API: login, outlets, outlet intelligence, shelf audit with an
  offline upload queue, detection review, order, visit history, manager dashboards.

Measured, not assumed: on the two-image smoke set the existing OpenCV baseline finds
6 and 2 of 12 facings and has a mean share-of-shelf error of 37.5 points. It is a
placeholder. Shelf numbers are only meaningful on the human-verified basis until a
real detector is trained (M5) or the LLM recogniser is benchmarked (M4).

Not done yet:

* The closed-set LLM recogniser is implemented and unit-tested against a fake client,
  but has never been run against the real API (no key was available).
* Postgres has not been exercised (no database server was available); only SQLite.
* The Render blueprint is updated but not deployed.
* The app still uses a simulated GPS position, keeps the session token in memory only,
  and has no Bangla UI strings yet.
* Voice: only the deterministic pre-call brief exists. No recording, no transcription.
* No real Square data has been loaded; everything shown is synthetic.

### Status on 10 October 2026: store type → photos → report → automatic order

Built and covered by tests (87 backend, 8 app):

* **Store types.** Channels carry `is_store_type`, display order, icon and restock depth
  (`units_per_facing`, inherited down the tree). The demo seeds six as placeholders until
  Square confirms its own. A visit starts with the officer choosing one; if it differs from
  the outlet's record, the outlet's channel follows (audited, `store_type_source = field`)
  and the visit stores both. Admins manage them through `/v2/admin/channels`.
* **Field registration** of shops not in the outlet master: unverified, assigned to the
  officer, possible duplicates within 50 m reported.
* **Whole-shelf recognition** (`vision/claude_shelf.py`): closed-set SKU identification of
  own and competitor products from the full photo, with catalogue pack shots
  (`ReferenceImage`, CLI importer). Falls back to the OpenCV baseline when the API fails.
  `auto` selects it when Anthropic credentials exist. Not yet run against the live API.
* **Shelf-driven ordering** (`domain/orders.py`, `services/ordering.py`): per product the
  larger of the usual order and the units needed to restore target facings (core assortment
  and product placement rules) — only on shelves that were photographed and identified at
  SKU level; accepted recommendations add to it; pack multiples round it up. Submitting a
  visit creates the order (`SHELFSIGHT_AUTO_ORDER`: confirm | draft | off), idempotently,
  skipped if the officer already ordered in that visit; it stays editable and cancellable
  for 24 h with the original suggestion kept per line.
* **Visit report** (`services/reports.py`, `GET /v2/visits/{id}/report`): store type and
  change, photos and models, share of shelf by company, brand, SKU and rack, must-stock
  availability (missing / low / on shelf / not photographed), placement, actions, the order,
  and a plain-text summary for messaging apps.
* **Training export** of fully reviewed photos (YOLO facings + SKU crops), excluding any
  image in an evaluation manifest.

Still open: real Square data, Bangla UI strings, real GPS, Postgres and Render not exercised,
and a measured accuracy figure for `claude-shelf` on a field holdout.

After 11 October: M3 offline-first hardening, M4 multimodal SKU recognition at
scale, M5 trained detector on field data, M6 planogram depth, M7 ML
classification, M8 order optimisation, M9 sales-call assistant, M10 closed loop.

## 7. First vertical slice

The demo walks one outlet end to end, all on clearly labelled synthetic data:

1. Catalogue loaded: own brands (Square) and competitors (Unilever, Reckitt,
   Kohinoor, ACI, Keya, Marico) across soap, hand wash, hair oil, detergent,
   toothpaste; pack sizes and price tiers.
2. Channels and outlets loaded across territories, with officers assigned.
3. Six months of synthetic own-brand orders.
4. Outlet opens on the phone: classification with evidence, scores per dimension.
5. Portfolio view: current own mix vs target vs channel vs peer benchmark.
6. Gaps: "0 units of SKU-X; 74% of 31 peer outlets bought it, avg 5.8 units/month".
7. Own-vs-competitor view from shelf observations.
8. Shelf photo captured, uploaded (queued if offline), analysed by a versioned model.
9. Low-confidence detections flagged; officer corrects; corrections stored.
10. Share of shelf and facings on verified basis; placement compliance against
    channel rules.
11. Recommendations with reason, evidence, confidence, priority; accept/modify/reject.
12. Suggested order lines derived from accepted recommendations and history.
13. Pre-call brief grounded in all of the above (deterministic; voice comes later).

Synthetic data generator: deterministic seed, its own organization, every row
`data_origin = synthetic`, every API response from that org carries
`"data_origin": "synthetic"` and the app shows a SYNTHETIC banner.

## 8. Assumptions and unknowns

Assumptions taken (lowest-risk, all configurable):

* A1. "3D picture" = spatial shelf understanding from ordinary photos (Section 5).
* A2. "Portfolio ratio" = the mix of own brands/categories/SKUs/pack sizes within
  an outlet's purchases, compared with targets and peers.
* A3. Channel taxonomy and outlet classes are unknown → configurable trees, seeded
  with a plausible starting set marked as synthetic.
* A4. Order history = secondary sales (distributor → outlet) at SKU level.
* A5. The Sales Officer is the primary capture user; supervisors review exceptions.
* A6. Outlets are pre-registered master data; ad-hoc outlet creation in the field
  is allowed but flagged for verification.
* A7. Single company (Square Toiletries) at launch; multi-business-unit isolation
  supported through `organization_id`.

Unknowns that block later milestones (questions for Square):

* U1. What exactly did "3-dimensional picture format" mean to the requester?
* U2. Which categories are in scope first? (The existing app assumes soap.)
* U3. Where does secondary sales data live (DMS vendor?), and can we get an export?
* U4. Existing channel and outlet-class definitions, and planogram guidelines.
* U5. Is the voice assistant meant for coaching during real customer conversations,
  or for rehearsal ("demo call") before visiting? Consent and recording policy?
* U6. Target devices (Android versions, RAM) and data-plan constraints of officers.
* U7. Hosting constraints (cloud region, data residency, which vendors are allowed
  to process images and audio).

## 9. Highest-risk architectural decisions

| Decision | Risk | Mitigation |
|---|---|---|
| Own and competitor products in one `product` table | Competitor master data is incomplete and messy | `is_verified` on products; field observations can create provisional competitor SKUs that a brand manager merges |
| Closed-set LLM recognition as V1 | Vendor cost, latency, accuracy on Bangla packaging unknown; images leave the device to a third party | Provider interface; per-inference cost/latency logged; benchmark on holdout before relying on it; confirm data-processing approval (U7) |
| Modular monolith + DB-backed job queue (no broker) | Throughput ceiling | Jobs are idempotent rows; swap the worker for a broker later without schema change |
| SQLite in dev/tests, Postgres in production | Dialect drift | Only portable SQLAlchemy types; CI runs migrations against Postgres before release |
| Rule-based classification first | Classes may not match how Square thinks about outlets | Schemes are data; ML classifier can be added as another `source` |
| Synthetic demo data | Stakeholders mistake it for insight | Separate organization, `data_origin` everywhere, visible banner, explicit statement in the update |
| Offline capture queue on device | Lost or duplicated uploads | Client-generated capture ids, server idempotency, sha256 duplicate detection, retry with backoff |
| Voice deferred | Stakeholder expectation | Pre-call brief ships now on the same data; voice design documented; real calls needed to choose STT |

Decision checklist applied to every change: does it preserve historical
evidence; can the business change the rule without a deploy; can a human
override the AI; can we explain and measure the recommendation; does it work on
an unreliable connection; can we debug it six months later.

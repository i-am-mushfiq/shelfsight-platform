"""Operations CLI: python -m retail_platform.cli <command>"""

from __future__ import annotations

import argparse
import json
import sys
import time
from datetime import date
from pathlib import Path

from sqlalchemy import select

from . import db, jobs
from .main import migrate
from .models import Organization, Outlet, User, Visit, new_id
from .security import Principal
from .seed import synthetic
from .services import intelligence


def _org(session, slug: str) -> Organization:  # type: ignore[no-untyped-def]
    org = session.execute(select(Organization).where(Organization.slug == slug)).scalar_one_or_none()
    if org is None:
        sys.exit(f"Organization {slug!r} not found")
    return org


def cmd_migrate(_: argparse.Namespace) -> None:
    migrate()
    print("database migrated to head")


def cmd_seed(args: argparse.Namespace) -> None:
    migrate()
    with db.session_factory()() as session:
        if args.reset:
            synthetic.reset(session)
            session.commit()
        anchor = date.fromisoformat(args.anchor) if args.anchor else None
        summary = synthetic.seed(session, anchor=anchor)
        session.commit()
        written = intelligence.classify_outlets(session, summary.organization_id, synthetic.ORIGIN, anchor)
        session.commit()
        outlet_ids = list(session.execute(select(Outlet.id).where(Outlet.organization_id == summary.organization_id)).scalars())
        for outlet_id in outlet_ids:
            intel = intelligence.analyze(session, summary.organization_id, outlet_id, anchor)
            intelligence.persist(session, summary.organization_id, intel, synthetic.ORIGIN)
        session.commit()
        sfbl = None
        if not args.no_sfbl and (SFBL_DIR / "products.csv").is_file():
            from .services.sfbl_import import import_catalog

            sfbl = import_catalog(session, session.get(Organization, summary.organization_id), SFBL_DIR)
            session.commit()
    print(json.dumps({**summary.__dict__, "classifications": written, "intelligence_refreshed": len(outlet_ids),
                      "square_food_catalogue": {"products": sfbl.products_created, "pack_shots": sfbl.pack_shots_added}
                      if sfbl else "not imported",
                      "login": {"employee_ids": summary.users, "password": synthetic.DEMO_PASSWORD},
                      "warning": "SYNTHETIC DATA — not real market or sales data"}, indent=2))


def cmd_classify(args: argparse.Namespace) -> None:
    with db.session_factory()() as session:
        org = _org(session, args.org)
        written = intelligence.classify_outlets(session, org.id, org.data_origin)
        session.commit()
    print(f"{written} classification assessments written")


def cmd_refresh(args: argparse.Namespace) -> None:
    with db.session_factory()() as session:
        org = _org(session, args.org)
        ids = list(session.execute(select(Outlet.id).where(Outlet.organization_id == org.id, Outlet.is_active.is_(True))).scalars())
        for outlet_id in ids:
            intelligence.persist(session, org.id, intelligence.analyze(session, org.id, outlet_id), org.data_origin)
        session.commit()
    print(f"refreshed {len(ids)} outlets")


def cmd_worker(args: argparse.Namespace) -> None:
    worker = jobs.Worker(db.session_factory(), interval=args.interval)
    worker.start()
    print("worker running; Ctrl+C to stop")
    try:
        while worker.is_alive():
            time.sleep(1)
    except KeyboardInterrupt:
        worker.stop()


def cmd_demo_audit(args: argparse.Namespace) -> None:
    """Run a real shelf audit (upload → inference → measurements) for an outlet from an image file."""
    from .vision import pipeline

    image = Path(args.image).read_bytes()
    with db.session_factory()() as session:
        org = _org(session, args.org)
        outlet = session.execute(select(Outlet).where(Outlet.organization_id == org.id, Outlet.code == args.outlet)).scalar_one()
        user = session.execute(select(User).where(User.organization_id == org.id, User.employee_id == args.officer)).scalar_one()
        principal = Principal(user.id, org.id, user.role, user.territory_id, org.data_origin)
        visit = Visit(organization_id=org.id, data_origin=org.data_origin, outlet_id=outlet.id, user_id=user.id,
                      client_visit_id=f"cli-{new_id()}")
        session.add(visit)
        session.flush()
        result = pipeline.ingest_capture(session, principal, visit, image, None, args.image, f"cli-{new_id()}",
                                         "CLI demo", None, None, {"source": "cli"})
        session.commit()
        jobs.drain(db.session_factory())
        session.expire_all()
        capture = session.get(type(result.capture), result.capture.id)
        print(json.dumps({"visit_id": visit.id, "capture_id": capture.id, "status": capture.status,
                          "quality": capture.quality}, indent=2, default=str))


def cmd_evaluate(args: argparse.Namespace) -> None:
    """Evaluate the configured vision provider on a manifest; --record stores an EvaluationRun."""
    from dataclasses import asdict

    from .config import get_settings
    from .evaluation import evaluate
    from .models import EvaluationRun
    from .vision.pipeline import catalog_for
    from .vision.registry import ensure_model_version, get_provider

    provider = get_provider(get_settings())
    with db.session_factory()() as session:
        org = _org(session, args.org)
        catalog, own = catalog_for(session, org.id, None)
        report = evaluate(provider, Path(args.manifest), catalog, own)
        if args.record:
            version = ensure_model_version(session, org.id, provider)
            session.add(EvaluationRun(organization_id=org.id, data_origin=org.data_origin, model_version_id=version.id,
                                      dataset=report.dataset, dataset_sha256=report.dataset_sha256,
                                      metrics={**report.metrics, "purpose": report.purpose},
                                      per_class=report.per_class, slices=report.slices))
            session.commit()
    print(json.dumps({"provider": provider.provider, "version": provider.version, **asdict(report)}, indent=2, default=str))


IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".webp"}
SFBL_DIR = Path("datasets/sfbl_catalog")


def cmd_import_sfbl(args: argparse.Namespace) -> None:
    """Load the scraped Square Food & Beverage catalogue and its pack shots."""
    from dataclasses import asdict

    from .services.sfbl_import import import_catalog

    with db.session_factory()() as session:
        summary = import_catalog(session, _org(session, args.org), Path(args.dir))
        session.commit()
    print(json.dumps(asdict(summary), indent=2))


def cmd_import_pack_shots(args: argparse.Namespace) -> None:
    """Load catalogue pack shots from a folder. File names are SKUs: SQ-MER-SOAP-100.jpg, or
    SQ-MER-SOAP-100__back.png for another view (front, back, side, top, angle)."""
    from .models import Product
    from .services import reference_images

    folder = Path(args.dir)
    files = sorted(f for f in folder.iterdir() if f.suffix.lower() in IMAGE_SUFFIXES)
    report = {"imported": [], "already_present": [], "unknown_sku": [], "rejected": []}
    with db.session_factory()() as session:
        org = _org(session, args.org)
        for path in files:
            sku, _, view = path.stem.partition("__")
            product = session.execute(select(Product).where(Product.organization_id == org.id,
                                                            Product.sku == sku)).scalar_one_or_none()
            if product is None:
                report["unknown_sku"].append(path.name)
                continue
            try:
                result = reference_images.add_reference_image(session, org.id, org.data_origin, product,
                                                               path.read_bytes(), path.name, view or "front")
            except reference_images.ReferenceImageRejected as exc:
                report["rejected"].append(f"{path.name}: {exc}")
                continue
            report["imported" if result.created else "already_present"].append(path.name)
        session.commit()
    print(json.dumps({k: (v if k != "imported" else len(v)) for k, v in report.items()}, indent=2))


def cmd_export_training(args: argparse.Namespace) -> None:
    from dataclasses import asdict

    from .training_export import export, holdout_hashes

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    excluded = holdout_hashes(Path(args.eval_dir)) if args.eval_dir else set()
    with db.session_factory()() as session:
        summary = export(session, _org(session, args.org), out, excluded)
    print(json.dumps({"out": str(out), **asdict(summary)}, indent=2))


def main() -> None:
    parser = argparse.ArgumentParser(prog="retail_platform")
    sub = parser.add_subparsers(required=True)
    sub.add_parser("migrate").set_defaults(fn=cmd_migrate)
    seed = sub.add_parser("seed", help="Load the isolated SYNTHETIC demo organization")
    seed.add_argument("--reset", action="store_true", help="Delete and rebuild the synthetic organization")
    seed.add_argument("--anchor", help="Last day of synthetic history (YYYY-MM-DD); default today")
    seed.add_argument("--no-sfbl", action="store_true", help="Skip importing datasets/sfbl_catalog")
    seed.set_defaults(fn=cmd_seed)
    for name, fn in (("classify", cmd_classify), ("refresh", cmd_refresh)):
        p = sub.add_parser(name)
        p.add_argument("--org", default=synthetic.SLUG)
        p.set_defaults(fn=fn)
    worker = sub.add_parser("worker")
    worker.add_argument("--interval", type=float, default=1.0)
    worker.set_defaults(fn=cmd_worker)
    audit = sub.add_parser("demo-audit")
    audit.add_argument("--org", default=synthetic.SLUG)
    audit.add_argument("--outlet", default="S-101")
    audit.add_argument("--officer", default="SO-1001")
    audit.add_argument("--image", default="test_assets/shelf-square-high-6-of-12.png")
    audit.set_defaults(fn=cmd_demo_audit)
    evaluation = sub.add_parser("evaluate")
    evaluation.add_argument("--org", default=synthetic.SLUG)
    evaluation.add_argument("--manifest", default="datasets/eval/smoke-v0/manifest.json")
    evaluation.add_argument("--record", action="store_true")
    evaluation.set_defaults(fn=cmd_evaluate)
    sfbl = sub.add_parser("import-sfbl-catalog", help="Load the scraped Square Food catalogue and pack shots")
    sfbl.add_argument("--org", default=synthetic.SLUG)
    sfbl.add_argument("--dir", default=str(SFBL_DIR))
    sfbl.set_defaults(fn=cmd_import_sfbl)
    shots = sub.add_parser("import-pack-shots", help="Load catalogue pack shots named by SKU from a folder")
    shots.add_argument("--org", default=synthetic.SLUG)
    shots.add_argument("--dir", required=True)
    shots.set_defaults(fn=cmd_import_pack_shots)
    training = sub.add_parser("export-training", help="Export fully reviewed shelf photos as training data")
    training.add_argument("--org", default=synthetic.SLUG)
    training.add_argument("--out", required=True)
    training.add_argument("--eval-dir", default="datasets/eval",
                          help="Images in any manifest here are never exported (holdout protection)")
    training.set_defaults(fn=cmd_export_training)
    args = parser.parse_args()
    db.configure()
    args.fn(args)


if __name__ == "__main__":
    main()

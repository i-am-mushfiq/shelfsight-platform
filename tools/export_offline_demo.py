"""Exports the demo data the app needs to run without a server (assets/demo/snapshot.json).

Builds a fresh synthetic organisation in a temporary database (the same `seed` the demo
server runs), then asks the real API for everything the field app reads: sign-in users,
shops, intelligence, pre-call briefs, suggested orders, catalogue, store types and the
supervisor dashboards. Also exports the inputs the phone needs to compute what changes
during a demo — shelf rules, must-stock lists, usual order sizes, promotions — so visit
reports, automatic orders and recommendations are worked out on the phone the same way.

A shop registered on the phone has no history; its intelligence comes from a template per
store type, made by registering a shop of that type here.

Usage: python tools/export_offline_demo.py [--out assets/demo/snapshot.json]
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from dataclasses import asdict
from datetime import date, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TEMPLATE_OUTLET = "__outlet__"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default=str(ROOT / "assets" / "demo" / "snapshot.json"))
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix="shelfsight-offline-"))
    env = {**os.environ, "SHELFSIGHT_DATABASE_URL": f"sqlite:///{(work / 'demo.db').as_posix()}",
           "SHELFSIGHT_BLOB_DIR": str(work / "blobs"), "SHELFSIGHT_RUN_WORKER": "0", "SHELFSIGHT_JSON_LOGS": "0",
           "SHELFSIGHT_MIGRATE_ON_START": "0", "SHELFSIGHT_VISION_PROVIDER": "mock"}
    subprocess.run([sys.executable, "-m", "retail_platform.cli", "seed", "--reset"], cwd=ROOT, env=env, check=True,
                   stdout=subprocess.DEVNULL)
    os.environ.update(env)
    sys.path.insert(0, str(ROOT))
    snapshot = export()
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(snapshot, ensure_ascii=False, separators=(",", ":"), default=float), encoding="utf-8")
    print(f"wrote {out} ({out.stat().st_size / 1e6:.1f} MB): {len(snapshot['outlets'])} shops, "
          f"{len(snapshot['users'])} users, {len(snapshot['products'])} products")


def export() -> dict:
    from fastapi.testclient import TestClient
    from sqlalchemy import select

    from retail_platform import db
    from retail_platform.domain import orders as order_domain
    from retail_platform.main import create_app
    from retail_platform.models import (
        Brand,
        Category,
        Distributor,
        Channel,
        CompetitorObservation,
        Manufacturer,
        Order,
        OrderItem,
        Organization,
        Outlet,
        OutletAssignment,
        OutletScore,
        Recommendation,
        Territory,
        User,
    )
    from retail_platform.seed import synthetic
    from retail_platform.services import loaders, ordering

    client = TestClient(create_app(run_worker=False, auto_migrate=False, mount_legacy=False))

    def login(employee_id: str) -> dict:
        response = client.post("/v2/auth/login", json={"employee_id": employee_id, "password": synthetic.DEMO_PASSWORD})
        response.raise_for_status()
        return response.json()

    def get(token: str, path: str, **params) -> object:
        response = client.get(path, params=params, headers={"Authorization": f"Bearer {token}"})
        response.raise_for_status()
        return response.json()

    def post(token: str, path: str, body: dict | None = None) -> dict:
        response = client.post(path, json=body or {}, headers={"Authorization": f"Bearer {token}"})
        response.raise_for_status()
        return response.json()

    session = db.session_factory()()
    org = session.execute(select(Organization).where(Organization.slug == synthetic.SLUG)).scalar_one()
    oid = org.id
    today = date.today()

    # --- users and what each one sees ----------------------------------------------------------
    users, tokens = {}, {}
    for user in session.execute(select(User).where(User.organization_id == oid, User.is_active.is_(True))
                                .order_by(User.employee_id)).scalars():
        body = login(user.employee_id)
        tokens[user.employee_id] = body["access_token"]
        users[user.employee_id] = {"user": body["user"], "password": synthetic.DEMO_PASSWORD}
    for employee_id, token in tokens.items():
        users[employee_id]["outlet_ids"] = [o["id"] for o in get(token, "/v2/outlets", limit=1000)]
        if users[employee_id]["user"]["role"] != "sales_officer":
            users[employee_id]["analytics"] = {
                **{f"overview:{g}": get(token, "/v2/analytics/overview", group_by=g)
                   for g in ("territory", "outlet", "officer", "channel")},
                **{f"competition:{g}": get(token, "/v2/analytics/competition", group_by=g)
                   for g in ("channel", "territory")},
            }
    officer = next(e for e, u in users.items() if u["user"]["role"] == "sales_officer")
    supervisor = next((e for e, u in users.items() if u["user"]["role"] in {"admin", "management"}), officer)

    # --- catalogue -----------------------------------------------------------------------------
    token = tokens[supervisor]
    products_api = get(token, "/v2/catalog/products")
    categories_api = get(token, "/v2/catalog/categories")
    store_types_api = get(token, "/v2/catalog/store-types")
    product_info = {pid: asdict(p) for pid, p in loaders.load_products(session, oid, today).items()}
    descendants = {k: sorted(v) for k, v in loaders.category_descendants(session, oid).items()}
    manufacturers = [{"id": m.id, "name": m.name, "is_own": m.is_own} for m in session.execute(
        select(Manufacturer).where(Manufacturer.organization_id == oid)).scalars()]
    brands = [{"id": b.id, "name": b.name, "manufacturer_id": b.manufacturer_id} for b in session.execute(
        select(Brand).where(Brand.organization_id == oid)).scalars()]
    categories = {c.id: c.name for c in session.execute(select(Category).where(Category.organization_id == oid)).scalars()}
    channels = {}
    for channel in session.execute(select(Channel).where(Channel.organization_id == oid)).scalars():
        channels[channel.id] = {"id": channel.id, "code": channel.code, "name": channel.name, "name_bn": channel.name_bn,
                                "icon": channel.icon, "path": channel.path, "is_store_type": channel.is_store_type,
                                "units_per_facing": ordering.units_per_facing(session, channel.id)}
    core, _ = loaders.load_core(session, oid)
    rules, rule_set = loaders.load_placement_rules(session, oid)
    territories = {t.id: {"id": t.id, "code": t.code, "name": t.name, "kind": t.kind, "path": t.path}
                   for t in session.execute(select(Territory).where(Territory.organization_id == oid)).scalars()}

    # --- shops ---------------------------------------------------------------------------------
    outlet_info = loaders.load_outlets(session, oid)
    summaries = {}
    for employee_id, token in tokens.items():
        for row in get(token, "/v2/outlets", limit=1000):
            summaries[row["id"]] = row

    def shop(outlet_id: str, token: str) -> dict:
        outlet = session.get(Outlet, outlet_id)
        info = loaders.load_outlets(session, oid)[outlet_id]
        intelligence = post(token, f"/v2/outlets/{outlet_id}/intelligence:refresh")
        session.expire_all()
        keys = dict(session.execute(select(Recommendation.id, Recommendation.dedupe_key)
                                    .where(Recommendation.outlet_id == outlet_id)).all())
        for rec in intelligence["recommendations"]:
            rec["dedupe_key"] = keys.get(rec["id"])
        recs = [r for r in intelligence["recommendations"] if r["source"].startswith("portfolio.")]
        # Usual order sizes over the suggestion window, and the price paid, from order history.
        lines = loaders.load_order_lines(session, oid, today - timedelta(days=ordering.HISTORY_DAYS))
        start = today - timedelta(days=90)
        history = [l for l in lines if l.outlet_id == outlet_id and start < l.order_date <= today]
        order_days = len({l.order_date for l in history})
        units, value = {}, {}
        for line in history:
            units[line.product_id] = units.get(line.product_id, 0) + line.quantity
            value[line.product_id] = value.get(line.product_id, 0.0) + line.value
        promos = ordering.active_promotions(session, oid, info.channel_path, today)
        recent = session.execute(select(Order).where(Order.outlet_id == outlet_id, Order.status == "confirmed")
                                 .order_by(Order.order_date.desc()).limit(3)).scalars().all()
        brief = get(token, f"/v2/outlets/{outlet_id}/call-brief")
        names = {m["id"]: m["name"] for m in manufacturers}
        notes = [{"id": o.id, "source": o.source,
                  "text": f"{names.get(o.manufacturer_id, 'Competitor')} "
                          f"{product_info[o.product_id]['name'] if o.product_id in product_info else ''}"
                          f" seen at BDT {o.observed_price:g}" if o.observed_price else (o.notes or "")}
                 for o in session.execute(select(CompetitorObservation).where(CompetitorObservation.outlet_id == outlet_id)
                                          .order_by(CompetitorObservation.observed_at.desc()).limit(3)).scalars()]
        # Facts the supervisor dashboards add up (api/analytics.py), so they can be recomputed
        # on the phone with the visits made during a demo.
        since, months = today - timedelta(days=90), 90 / 30.44
        sold = sum(float(v) for v in session.execute(
            select(OrderItem.line_value).join(Order, OrderItem.order_id == Order.id)
            .where(Order.outlet_id == outlet_id, Order.order_date > since, Order.status == "confirmed")).scalars())
        scores = {}
        for dimension, score in session.execute(select(OutletScore.dimension, OutletScore.value)
                                                .where(OutletScore.outlet_id == outlet_id)
                                                .order_by(OutletScore.computed_at)):
            scores[dimension] = score
        officer_row = session.execute(select(User.id, User.name).join(OutletAssignment, OutletAssignment.user_id == User.id)
                                      .where(OutletAssignment.outlet_id == outlet_id)).first()
        distributor = session.get(Distributor, outlet.distributor_id) if outlet.distributor_id else None
        return {
            "analytics": {
                "monthly_value_bdt": sold / months, "scores": scores,
                "groups": {"territory": [outlet.territory_id, territories[outlet.territory_id]["name"]],
                           "channel": [info.channel_id, channels[info.channel_id]["name"]],
                           "officer": list(officer_row) if officer_row else ["none", "Unassigned"],
                           "distributor": [distributor.id, distributor.name] if distributor else ["none", "Unassigned"],
                           "outlet": [outlet.id, outlet.name]},
            },
            "summary": summaries.get(outlet_id) or get(token, f"/v2/outlets/{outlet_id}"),
            "code": outlet.code, "address": outlet.address, "is_verified": outlet.is_verified,
            "lat": outlet.lat, "lng": outlet.lng, "territory_id": outlet.territory_id,
            "channel_id": info.channel_id, "class_id": info.class_id,
            "classification": intelligence["classification"],
            "intelligence": intelligence,
            "portfolio_recommendations": recs,
            "suggested_order": get(token, f"/v2/outlets/{outlet_id}/suggested-order"),
            # The server's answers, kept so tests can check the phone works them out the same.
            "call_brief": brief,
            "history": {"order_days": order_days, "window_days": 90,
                        "units": units, "value": {k: round(v, 2) for k, v in value.items()}},
            "promoted_product_ids": sorted({pid for _, pids in promos for pid in pids}),
            "brief": {
                "promotions": [{"id": p.id, "name": p.name, "mechanic": p.mechanic, "ends_on": p.ends_on.isoformat(),
                                "products": [product_info[pid]["name"] for pid in pids if pid in product_info]}
                               for p, pids in promos],
                "last_orders": brief["last_orders"],
                "competitor_notes": notes,
                "channel": channels[info.channel_id]["name"],
            },
        }

    officer_of = dict(session.execute(select(OutletAssignment.outlet_id, OutletAssignment.user_id)).all())
    outlets = {}
    for outlet_id in sorted(summaries):
        employee = next((e for e, u in users.items() if u["user"]["id"] == officer_of.get(outlet_id)), supervisor)
        outlets[outlet_id] = shop(outlet_id, tokens[employee])
        print(f"  {len(outlets)}/{len(summaries)} {outlets[outlet_id]['summary']['name']}", flush=True)

    # A shop registered on the phone: intelligence of a new shop of each store type.
    templates = {}
    officer_token = tokens[officer]
    for store_type in store_types_api:
        created = post(officer_token, "/v2/outlets", {"client_outlet_id": f"template-{store_type['code']}".lower(),
                                                      "name": "New shop", "store_type_id": store_type["id"]})
        template = shop(created["id"], officer_token)
        text = json.dumps(template, default=float).replace(created["id"], TEMPLATE_OUTLET)
        templates[store_type["id"]] = json.loads(text)
    officer_territory = {e: session.get(User, u["user"]["id"]).territory_id for e, u in users.items()}

    return {
        "version": 1,
        "generated_on": today.isoformat(),
        "organization": {"id": oid, "name": org.name},
        "data_origin": "synthetic",
        "users": {e: {**u, "territory_id": officer_territory[e]} for e, u in users.items()},
        "catalog": {"products": products_api, "categories": categories_api, "store_types": store_types_api},
        "products": product_info,
        "manufacturers": manufacturers,
        "brands": brands,
        "category_names": categories,
        "category_descendants": descendants,
        "channels": channels,
        "territories": territories,
        "core": [asdict(c) for c in core],
        "placement_rules": [asdict(r) for r in rules],
        "placement_rule_set": {"id": rule_set.id, "version": rule_set.version} if rule_set else None,
        "order_generator_version": order_domain.GENERATOR_VERSION,
        "outlets": outlets,
        "outlet_templates": templates,
        "template_outlet_id": TEMPLATE_OUTLET,
    }


if __name__ == "__main__":
    main()

"""The sales officer's flow end to end: pick (or register) a shop, say what kind of store it is,
photograph the racks, review what was detected, submit — and get the report and the order."""

from __future__ import annotations

import uuid
from dataclasses import replace

import pytest
from sqlalchemy import select

from retail_platform import config, db, jobs
from retail_platform.models import AuditLog, Order
from retail_platform.vision import registry
from retail_platform.vision.base import ProviderDetection
from retail_platform.vision.fake import ScriptedProvider

from .conftest import login, shelf_jpeg

STORE_TYPE_ORDER = ["GT-GROC", "GT-COS", "GT-DEPT", "MT-SS", "PH", "WS"]


def _store_types(client, headers) -> dict[str, dict]:
    return {t["code"]: t for t in client.get("/v2/catalog/store-types", headers=headers).json()}


def _register(client, headers, store_type_id: str, **extra) -> dict:
    body = {"client_outlet_id": uuid.uuid4().hex, "name": "Notun Bazar Store", "owner_name": "Owner (synthetic)",
            "store_type_id": store_type_id, **extra}
    response = client.post("/v2/outlets", headers=headers, json=body)
    assert response.status_code == 201, response.text
    return response.json()


@pytest.fixture
def cosmetics_shelf(ids):
    """One untagged photo of a mixed rack: 3 Lux and 2 Sunsilk (competitor), 1 Meril soap, 1 unidentified."""
    sq, uni = ids["manufacturers"]["SQ"], ids["manufacturers"]["UNI"]
    p = ids["products"]
    detections = [ProviderDetection(0.05 + i * 0.15, 0.05, 0.12, 0.25, "competitor", 0.93, p["UNI-LUX-100"], uni)
                  for i in range(3)]
    detections += [ProviderDetection(0.05 + i * 0.15, 0.40, 0.12, 0.25, "competitor", 0.91, p["UNI-SUN-180"], uni)
                   for i in range(2)]
    detections.append(ProviderDetection(0.40, 0.40, 0.12, 0.25, "own", 0.88, p["SQ-MER-SOAP-100"], sq))
    detections.append(ProviderDetection(0.60, 0.72, 0.12, 0.25, "unknown", 0.30))
    provider = ScriptedProvider(detections)
    registry.set_provider(provider)
    yield provider
    registry.set_provider(None)


def _visit_with_photo(client, headers, outlet_id: str, store_type_id: str | None) -> dict:
    visit = client.post("/v2/visits", headers=headers, json={
        "client_visit_id": uuid.uuid4().hex, "outlet_id": outlet_id, "store_type_id": store_type_id}).json()
    upload = client.post(f"/v2/visits/{visit['id']}/captures", headers=headers,
                         files={"image": ("rack.jpg", shelf_jpeg(uuid.uuid4().int % 1000), "image/jpeg")},
                         data={"client_capture_id": uuid.uuid4().hex})
    assert upload.status_code == 201, upload.text
    jobs.drain(db.session_factory())
    return visit


def test_six_store_types_in_display_order(platform, officer):
    types = platform["client"].get("/v2/catalog/store-types", headers=officer).json()
    assert [t["code"] for t in types] == STORE_TYPE_ORDER
    assert all(t["icon"] and t["description"] and t["name_bn"] for t in types)
    assert {t["code"]: t["effective_units_per_facing"] for t in types}["WS"] == 12


def test_officer_registers_a_new_shop_in_the_field(platform, officer, supervisor):
    client = platform["client"]
    types = _store_types(client, officer)
    # Same coordinates as Shwapno Banani (S-101): flagged as a possible duplicate, still registered.
    outlet = _register(client, officer, types["PH"]["id"], lat=23.79385, lng=90.40672)
    assert outlet["code"].startswith("F-") and outlet["is_verified"] is False
    assert outlet["channel_code"] == "PH" and outlet["territory"] == "Banani–Gulshan"
    assert [d["code"] for d in outlet["possible_duplicates"]] == ["S-101"]
    mine = {o["id"] for o in client.get("/v2/outlets", headers=officer).json()}
    assert outlet["id"] in mine
    karim = login(client, "SO-1042")
    assert client.get(f"/v2/outlets/{outlet['id']}", headers=karim).status_code == 404

    channels = {c["code"]: c["id"] for c in client.get("/v2/catalog/channels", headers=officer).json()}
    bad = client.post("/v2/outlets", headers=officer, json={
        "client_outlet_id": uuid.uuid4().hex, "name": "X Store", "store_type_id": channels["GT"]})
    assert bad.status_code == 422  # a channel group is not a store type
    # A supervisor's home is an area: they must name the territory.
    assert client.post("/v2/outlets", headers=supervisor, json={
        "client_outlet_id": uuid.uuid4().hex, "name": "Y Store", "store_type_id": types["PH"]["id"]}).status_code == 422
    with db.session_factory()() as session:
        assert session.execute(select(AuditLog).where(AuditLog.action == "outlet.register",
                                                      AuditLog.entity_id == outlet["id"])).scalar_one()


def test_register_is_idempotent(platform, officer):
    client = platform["client"]
    body = {"client_outlet_id": uuid.uuid4().hex, "name": "Retry Store",
            "store_type_id": _store_types(client, officer)["GT-GROC"]["id"]}
    first = client.post("/v2/outlets", headers=officer, json=body)
    second = client.post("/v2/outlets", headers=officer, json=body)
    assert first.status_code == 201 and second.status_code == 200
    assert second.json()["id"] == first.json()["id"] and second.json()["replayed"] is True


def test_full_visit_store_type_photos_report_and_automatic_order(platform, officer, cosmetics_shelf, ids):
    client = platform["client"]
    types = _store_types(client, officer)
    outlet = _register(client, officer, types["GT-GROC"]["id"], name="Rupali Cosmetics")

    # At the shop the officer sees it is really a cosmetics store.
    visit = _visit_with_photo(client, officer, outlet["id"], types["GT-COS"]["id"])
    assert visit["store_type"]["code"] == "GT-COS" and visit["previous_store_type"]["code"] == "GT-GROC"
    assert client.get(f"/v2/outlets/{outlet['id']}", headers=officer).json()["channel_code"] == "GT-COS"

    suggestion = client.get(f"/v2/outlets/{outlet['id']}/suggested-order", headers=officer,
                            params={"visit_id": visit["id"]}).json()
    assert suggestion["shelf_evidence"]["visit_id"] == visit["id"]
    assert suggestion["units_per_facing"] == 2

    submitted = client.post(f"/v2/visits/{visit['id']}/submit", headers=officer)
    assert submitted.status_code == 200, submitted.text
    order = submitted.json()["order"]
    assert order["source"] == "auto" and order["status"] == "confirmed" and order["visit_id"] == visit["id"]
    lines = {line["sku"]: line for line in order["lines"]}
    # Core for cosmetics stores: Meril soap 100g (1 of 2 facings seen), Meril shampoo (0 of 2), Jui oil (oil
    # shelf not photographed, so not ordered). 2 units per facing in this store type.
    assert set(lines) == {"SQ-MER-SOAP-100", "SQ-MER-SHMP-180"}
    soap, shampoo = lines["SQ-MER-SOAP-100"], lines["SQ-MER-SHMP-180"]
    assert (soap["quantity"], shampoo["quantity"]) == (2, 4)
    assert soap["sources"][0]["status"] == "low" and soap["sources"][0]["uncertain"] is True  # 1 unidentified facing
    assert shampoo["sources"][0]["status"] == "missing" and shampoo["reasons"][0].startswith("Missing on shelf")
    assert order["value"] == round(2 * 39.6 + 4 * 167.2, 2)
    assert all(line["suggested_quantity"] == line["quantity"] for line in order["lines"])

    report = submitted.json()["report"]
    assert report["store_type"]["code"] == "GT-COS" and report["previous_store_type"]["code"] == "GT-GROC"
    assert report["outlet"]["is_verified"] is False and report["photos"]["analysed"] == 1
    shelf = report["shelf"]
    assert (shelf["total_facings"], shelf["own_facings"], shelf["competitor_facings"]) == (7, 1, 5)
    assert shelf["by_manufacturer"][0]["name"] == "Unilever Bangladesh" and shelf["by_manufacturer"][0]["facings"] == 5
    assert {b["name"]: b["facings"] for b in shelf["by_brand"]} == {"Lux": 3, "Sunsilk": 2, "Meril": 1}
    assert {p["sku"] for p in shelf["by_product"]} == {"UNI-LUX-100", "UNI-SUN-180", "SQ-MER-SOAP-100"}
    status = {a["product"]["sku"]: a["status"] for a in report["availability"]}
    assert status == {"SQ-MER-SHMP-180": "missing", "SQ-MER-SOAP-100": "low", "SQ-JUI-OIL-100": "not_checked"}
    shampoo_rule = next(r for r in report["placement"]["results"] if "shampoo" in r["description"])
    assert shampoo_rule["status"] == "non_compliant"
    assert report["order"]["id"] == order["id"]
    text = report["summary_text"]
    assert "Store type: Cosmetics & Toiletries (changed from Grocery (Mudi))" in text
    assert "Missing on shelf: Meril Herbal Shampoo 180ml" in text and "Order (auto, confirmed): 2 lines" in text
    assert "SYNTHETIC DEMO DATA" in text
    assert client.get(f"/v2/visits/{visit['id']}/report", headers=officer).json()["order"]["id"] == order["id"]

    # Submitting again changes nothing.
    again = client.post(f"/v2/visits/{visit['id']}/submit", headers=officer).json()
    assert again["order"]["id"] == order["id"]

    # The officer adjusts the order; the original suggestion is kept beside the final quantity.
    edited = client.put(f"/v2/orders/{order['id']}", headers=officer, json={"lines": [
        {"product_id": soap["product_id"], "quantity": 6},
        {"product_id": shampoo["product_id"], "quantity": 4},
        {"product_id": ids["products"]["SQ-JUI-OIL-100"], "quantity": 3}]}).json()
    edited_lines = {line["sku"]: line for line in edited["lines"]}
    assert edited_lines["SQ-MER-SOAP-100"]["quantity"] == 6
    assert edited_lines["SQ-MER-SOAP-100"]["suggested_quantity"] == 2
    assert edited_lines["SQ-MER-SOAP-100"]["sources"][0]["source"] == "shelf"
    assert edited_lines["SQ-JUI-OIL-100"]["suggested_quantity"] is None
    competitor = client.put(f"/v2/orders/{order['id']}", headers=officer, json={"lines": [
        {"product_id": ids["products"]["UNI-LUX-100"], "quantity": 1}]})
    assert competitor.status_code == 422
    karim = login(client, "SO-1042")
    assert client.post(f"/v2/orders/{order['id']}/cancel", headers=karim, json={"reason": "not mine"}).status_code == 404

    cancelled = client.post(f"/v2/orders/{order['id']}/cancel", headers=officer,
                            json={"reason": "Owner will order next week"}).json()
    assert cancelled["status"] == "cancelled" and cancelled["editable"] is False
    assert client.put(f"/v2/orders/{order['id']}", headers=officer, json={"lines": [
        {"product_id": soap["product_id"], "quantity": 1}]}).status_code == 409
    # A cancelled automatic order is not silently recreated, and the report says what happened.
    resubmitted = client.post(f"/v2/visits/{visit['id']}/submit", headers=officer).json()
    assert resubmitted["order"]["status"] == "cancelled"
    assert client.get(f"/v2/outlets/{outlet['id']}/orders", headers=officer).json()[0]["id"] == order["id"]
    with db.session_factory()() as session:
        actions = set(session.execute(select(AuditLog.action).where(AuditLog.entity_id.in_(
            [order["id"], outlet["id"]]))).scalars())
    assert {"order.auto_create", "order.update", "order.cancel", "outlet.store_type_change"} <= actions


def test_no_automatic_order_when_the_officer_already_ordered_in_the_visit(platform, officer, cosmetics_shelf, ids):
    client = platform["client"]
    types = _store_types(client, officer)
    outlet = _register(client, officer, types["GT-COS"]["id"])
    visit = _visit_with_photo(client, officer, outlet["id"], None)
    assert visit["store_type"]["code"] == "GT-COS" and visit["previous_store_type"] is None
    manual = client.post(f"/v2/outlets/{outlet['id']}/orders", headers=officer, json={
        "client_order_id": uuid.uuid4().hex, "visit_id": visit["id"],
        "lines": [{"product_id": ids["products"]["SQ-JUI-OIL-100"], "quantity": 5}]})
    assert manual.status_code == 201
    submitted = client.post(f"/v2/visits/{visit['id']}/submit", headers=officer).json()
    assert submitted["order"]["id"] == manual.json()["id"] and submitted["order"]["source"] == "app"
    with db.session_factory()() as session:
        assert session.execute(select(Order).where(Order.external_ref == f"AUTO-{visit['id']}")).first() is None


@pytest.mark.parametrize("mode", ["draft", "off"])
def test_auto_order_mode_is_configurable(platform, officer, cosmetics_shelf, mode):
    client = platform["client"]
    original = config.get_settings()
    config.override_settings(replace(original, auto_order=mode))
    try:
        outlet = _register(client, officer, _store_types(client, officer)["GT-COS"]["id"])
        visit = _visit_with_photo(client, officer, outlet["id"], None)
        order = client.post(f"/v2/visits/{visit['id']}/submit", headers=officer).json()["order"]
    finally:
        config.override_settings(original)
    if mode == "off":
        assert order is None
        return
    assert order["status"] == "draft"
    confirmed = client.post(f"/v2/orders/{order['id']}/confirm", headers=officer).json()
    assert confirmed["status"] == "confirmed"


def test_store_type_must_be_selectable(platform, officer):
    client = platform["client"]
    outlets = client.get("/v2/outlets", headers=officer).json()
    channels = {c["code"]: c["id"] for c in client.get("/v2/catalog/channels", headers=officer).json()}
    response = client.post("/v2/visits", headers=officer, json={
        "client_visit_id": uuid.uuid4().hex, "outlet_id": outlets[0]["id"], "store_type_id": channels["MT"]})
    assert response.status_code == 422


def test_admin_manages_store_types(platform, admin, officer):
    client = platform["client"]
    channels = {c["code"]: c for c in client.get("/v2/catalog/channels", headers=admin).json()}
    created = client.post("/v2/admin/channels", headers=admin, json={
        "code": "GT-KIOSK", "name": "Kiosk (Tong)", "parent_id": channels["GT"]["id"], "is_store_type": True,
        "sort_order": 7, "icon": "kiosk", "units_per_facing": 1})
    assert created.status_code == 201, created.text
    assert created.json()["path"] == "/gt/gt-kiosk/"
    assert [t["code"] for t in client.get("/v2/catalog/store-types", headers=officer).json()][-1] == "GT-KIOSK"
    patched = client.patch(f"/v2/admin/channels/{created.json()['id']}", headers=admin, json={"is_active": False})
    assert patched.json()["is_active"] is False
    assert [t["code"] for t in client.get("/v2/catalog/store-types", headers=officer).json()] == STORE_TYPE_ORDER
    assert client.post("/v2/admin/channels", headers=officer, json={"code": "NOPE", "name": "Nope"}).status_code == 403
    assert client.post("/v2/admin/channels", headers=admin, json={"code": "GT-KIOSK", "name": "Again"}).status_code == 409


def test_pack_shots_reach_the_recogniser_catalogue(platform, admin, officer, ids):
    from retail_platform.vision.pipeline import catalog_for

    client = platform["client"]
    product_id = ids["products"]["SQ-SEP-HW-200"]
    upload = client.post(f"/v2/admin/products/{product_id}/reference-images", headers=admin,
                         files={"image": ("sepnil.jpg", shelf_jpeg(42), "image/jpeg")}, data={"view": "front"})
    assert upload.status_code == 201, upload.text
    again = client.post(f"/v2/admin/products/{product_id}/reference-images", headers=admin,
                        files={"image": ("sepnil.jpg", shelf_jpeg(42), "image/jpeg")})
    assert again.status_code == 200 and again.json()["id"] == upload.json()["id"]
    assert client.post(f"/v2/admin/products/{product_id}/reference-images", headers=admin,
                       files={"image": ("x.jpg", b"not an image", "image/jpeg")}).status_code == 422
    assert client.post(f"/v2/admin/products/{product_id}/reference-images", headers=officer,
                       files={"image": ("s.jpg", shelf_jpeg(43), "image/jpeg")}).status_code == 403
    listed = client.get(f"/v2/catalog/products/{product_id}/reference-images", headers=officer).json()
    assert [r["id"] for r in listed] == [upload.json()["id"]]
    image = client.get(listed[0]["image_url"], headers=officer)
    assert image.status_code == 200 and image.headers["content-type"] == "image/jpeg"
    products = {p["id"]: p for p in client.get("/v2/catalog/products", headers=officer).json()}
    assert products[product_id]["reference_images"] == 1
    with db.session_factory()() as session:
        catalog, _ = catalog_for(session, platform["org_id"], None)
    with_shots = [e for e in catalog if e.reference_images]
    assert [e.product_id for e in with_shots] == [product_id]
    assert [e.sku for e in catalog] == sorted(e.sku for e in catalog)  # stable order for prompt caching
    assert client.delete(f"/v2/admin/reference-images/{upload.json()['id']}", headers=admin).status_code == 204
    assert client.get(f"/v2/catalog/products/{product_id}/reference-images", headers=officer).json() == []


def test_migrations_build_the_schema_from_scratch(tmp_path):
    from alembic import command
    from alembic.config import Config
    from sqlalchemy import create_engine, inspect

    from retail_platform.models import Base

    url = f"sqlite:///{(tmp_path / 'migrated.db').as_posix()}"
    alembic = Config("retail_platform/migrations/alembic.ini")
    alembic.set_main_option("script_location", "retail_platform/migrations")
    alembic.set_main_option("sqlalchemy.url", url)
    command.upgrade(alembic, "head")
    inspector = inspect(create_engine(url))
    for table in Base.metadata.sorted_tables:
        migrated = {c["name"] for c in inspector.get_columns(table.name)}
        assert {c.name for c in table.columns} <= migrated, table.name


def test_training_export_takes_only_fully_reviewed_photos_and_never_the_holdout(platform, officer, cosmetics_shelf,
                                                                               tmp_path):
    import json

    from retail_platform.models import Organization, ShelfCapture
    from retail_platform.training_export import export

    client = platform["client"]
    outlet = _register(client, officer, _store_types(client, officer)["GT-COS"]["id"])
    reviewed = _visit_with_photo(client, officer, outlet["id"], None)
    partial = _visit_with_photo(client, officer, outlet["id"], None)
    capture = client.get(f"/v2/visits/{reviewed['id']}", headers=officer).json()["captures"][0]
    for detection in client.get(f"/v2/captures/{capture['id']}", headers=officer).json()["detections"]:
        action = "reject" if detection["predicted"]["label"] == "unknown" else "confirm"
        client.post(f"/v2/detections/{detection['id']}/review", headers=officer, json={"action": action})
    with db.session_factory()() as session:
        org = session.get(Organization, platform["org_id"])
        partial_sha = session.execute(select(ShelfCapture.sha256).where(
            ShelfCapture.visit_id == partial["id"])).scalar_one()
        summary = export(session, org, tmp_path, excluded=set())
        reviewed_sha = session.get(ShelfCapture, capture["id"]).sha256
        holdout = export(session, org, tmp_path / "with-holdout", excluded={reviewed_sha})
    labels = list((tmp_path / "facings" / "labels").rglob(f"{capture['id']}.txt"))
    assert len(labels) == 1 and len(labels[0].read_text().splitlines()) == 6  # 7 boxes, 1 rejected
    assert all(line.startswith("0 ") for line in labels[0].read_text().splitlines())
    assert (tmp_path / "crops" / "UNI-LUX-100").is_dir() and (tmp_path / "crops" / "SQ-MER-SOAP-100").is_dir()
    assert summary.classes["UNI-LUX-100"] >= 3 and summary.skipped_partially_reviewed >= 1
    assert partial_sha != reviewed_sha
    assert holdout.skipped_holdout == 1
    assert not list((tmp_path / "with-holdout" / "facings" / "labels").rglob(f"{capture['id']}.txt"))
    assert json.loads((tmp_path / "manifest.json").read_text())["data_origin"] == "synthetic"


def test_pack_shots_import_from_a_folder_named_by_sku(platform, tmp_path, capsys):
    import argparse
    import json

    from retail_platform import cli

    (tmp_path / "SQ-JUI-OIL-200.jpg").write_bytes(shelf_jpeg(51))
    (tmp_path / "SQ-JUI-OIL-200__back.jpg").write_bytes(shelf_jpeg(52))
    (tmp_path / "NOT-A-SKU.jpg").write_bytes(shelf_jpeg(53))
    (tmp_path / "SQ-CHK-DET-1K.png").write_bytes(b"broken")
    (tmp_path / "notes.txt").write_text("ignored")
    cli.cmd_import_pack_shots(argparse.Namespace(org="demo-synthetic", dir=str(tmp_path)))
    first = json.loads(capsys.readouterr().out)
    assert first["imported"] == 2 and first["unknown_sku"] == ["NOT-A-SKU.jpg"] and len(first["rejected"]) == 1
    cli.cmd_import_pack_shots(argparse.Namespace(org="demo-synthetic", dir=str(tmp_path)))
    second = json.loads(capsys.readouterr().out)
    assert second["imported"] == 0 and len(second["already_present"]) == 2


def test_logo_only_detections_never_mark_products_missing(platform, officer, ids):
    """The OpenCV baseline knows "Square or not", not which SKU: its photos must not drive restocking."""
    client = platform["client"]
    sq = ids["manufacturers"]["SQ"]
    registry.set_provider(ScriptedProvider(
        [ProviderDetection(0.1 + i * 0.2, 0.3, 0.15, 0.3, "own", 0.9, None, sq) for i in range(2)]
        + [ProviderDetection(0.5 + i * 0.2, 0.3, 0.15, 0.3, "competitor", 0.5) for i in range(2)]))
    try:
        outlet = _register(client, officer, _store_types(client, officer)["GT-COS"]["id"])
        skin = next(c for c in client.get("/v2/catalog/categories", headers=officer).json() if c["code"] == "SKIN")
        visit = client.post("/v2/visits", headers=officer, json={
            "client_visit_id": uuid.uuid4().hex, "outlet_id": outlet["id"]}).json()
        client.post(f"/v2/visits/{visit['id']}/captures", headers=officer,
                    files={"image": ("rack.jpg", shelf_jpeg(61), "image/jpeg")},
                    data={"client_capture_id": uuid.uuid4().hex, "category_id": skin["id"]})
        jobs.drain(db.session_factory())
        submitted = client.post(f"/v2/visits/{visit['id']}/submit", headers=officer).json()
    finally:
        registry.set_provider(None)
    report = submitted["report"]
    assert report["shelf"]["own_facings"] == 2
    assert {a["status"] for a in report["availability"]} == {"not_checked"}
    assert "Missing on shelf" not in report["summary_text"]
    assert submitted["order"] is None  # a new shop with no history and no SKU-level evidence: nothing to order

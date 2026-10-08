from __future__ import annotations

import uuid

from sqlalchemy import select

from retail_platform import db, jobs
from retail_platform.models import AuditLog, Organization, Outlet, RecognitionCorrection, Role, User
from retail_platform.security import hash_password

from .conftest import login, shelf_jpeg


def _outlet(client, headers, code: str) -> dict:
    outlets = client.get("/v2/outlets", headers=headers).json()
    return next(o for o in outlets if o["code"] == code)


# --- auth & scoping --------------------------------------------------------------------------------


def test_login_rejects_bad_password(platform):
    response = platform["client"].post("/v2/auth/login", json={"employee_id": "SO-1001", "password": "nope"})
    assert response.status_code == 401


def test_requires_token(platform):
    assert platform["client"].get("/v2/outlets").status_code == 401


def test_synthetic_origin_is_announced(platform, officer):
    response = platform["client"].get("/v2/outlets", headers=officer)
    assert response.headers["X-Data-Origin"] == "synthetic"
    assert all(o["data_origin"] == "synthetic" for o in response.json())


def test_officer_sees_only_assigned_outlets(platform, officer, supervisor):
    client = platform["client"]
    mine = client.get("/v2/outlets", headers=officer).json()
    assert {o["territory"] for o in mine} == {"Banani–Gulshan"}
    team = client.get("/v2/outlets", headers=supervisor).json()
    assert {o["territory"] for o in team} == {"Banani–Gulshan", "Mirpur"}  # Dhaka North subtree only
    other = next(o for o in team if o["territory"] == "Mirpur")
    assert client.get(f"/v2/outlets/{other['id']}", headers=officer).status_code == 404


def test_tenant_isolation(platform, officer):
    with db.session_factory()() as session:
        org = Organization(slug=f"other-{uuid.uuid4().hex[:6]}", name="Other tenant")
        session.add(org)
        session.flush()
        session.add(User(organization_id=org.id, employee_id="SO-1001", name="Other", role=Role.ADMIN,
                         password_hash=hash_password("other-pass")))
        session.commit()
        slug = org.slug
    client = platform["client"]
    response = client.post("/v2/auth/login", json={"employee_id": "SO-1001", "password": "other-pass", "organization": slug})
    other = {"Authorization": f"Bearer {response.json()['access_token']}"}
    assert client.get("/v2/outlets", headers=other).json() == []
    synthetic_outlet = client.get("/v2/outlets", headers=officer).json()[0]
    assert client.get(f"/v2/outlets/{synthetic_outlet['id']}", headers=other).status_code == 404


def test_officer_cannot_change_rules(platform, officer):
    response = platform["client"].post("/v2/admin/rule-sets", headers=officer,
                                       json={"kind": "placement", "name": "x", "items": [{}]})
    assert response.status_code == 403


# --- portfolio intelligence ------------------------------------------------------------------------


def test_intelligence_has_evidence_backed_recommendations(platform, officer):
    client = platform["client"]
    outlet = _outlet(client, officer, "S-104")
    intel = client.post(f"/v2/outlets/{outlet['id']}/intelligence:refresh", headers=officer).json()
    assert intel["data_origin"] == "synthetic"
    assert intel["classification"]["evidence"]["reasons"]
    assert intel["portfolio"]["peer_group"]["size"] >= 5
    assert intel["recommendations"], "seeded data has deliberate gaps"
    for rec in intel["recommendations"]:
        assert rec["reason"] and rec["evidence"] and 0 <= rec["confidence"] <= 1
        assert rec["evidence"]["rule_sets"]["portfolio"]["version"] == 1
    dims = {s["dimension"]: s["value"] for s in intel["scores"]}
    assert dims["share_of_shelf"] is None  # no audit yet → not scored, not zero


def test_refresh_is_idempotent(platform, officer):
    client = platform["client"]
    outlet = _outlet(client, officer, "S-105")
    first = client.post(f"/v2/outlets/{outlet['id']}/intelligence:refresh", headers=officer).json()
    second = client.post(f"/v2/outlets/{outlet['id']}/intelligence:refresh", headers=officer).json()
    assert [r["id"] for r in first["recommendations"]] == [r["id"] for r in second["recommendations"]]


def test_feedback_and_rejection_cooldown(platform, officer):
    client = platform["client"]
    outlet = _outlet(client, officer, "S-104")
    recs = client.post(f"/v2/outlets/{outlet['id']}/intelligence:refresh", headers=officer).json()["recommendations"]
    target = recs[0]
    response = client.post(f"/v2/recommendations/{target['id']}/feedback", headers=officer,
                           json={"decision": "rejected", "note": "Owner refuses this SKU"})
    assert response.json()["status"] == "rejected"
    again = client.post(f"/v2/outlets/{outlet['id']}/intelligence:refresh", headers=officer).json()["recommendations"]
    assert target["id"] not in {r["id"] for r in again}
    keys = {r["evidence"].get("gap_kind") for r in again}
    assert keys  # others still present
    assert client.post(f"/v2/recommendations/{target['id']}/feedback", headers=officer,
                       json={"decision": "accepted"}).status_code == 409


def test_suggested_order_and_idempotent_order(platform, officer, ids):
    client = platform["client"]
    outlet = _outlet(client, officer, "S-103")
    client.post(f"/v2/outlets/{outlet['id']}/intelligence:refresh", headers=officer)
    suggestion = client.get(f"/v2/outlets/{outlet['id']}/suggested-order", headers=officer).json()
    assert suggestion["lines"]
    line = suggestion["lines"][0]
    body = {"client_order_id": uuid.uuid4().hex, "lines": [{"product_id": line["product_id"], "quantity": line["quantity"] + 1,
                                                             "suggested_quantity": line["quantity"]}]}
    first = client.post(f"/v2/outlets/{outlet['id']}/orders", headers=officer, json=body)
    second = client.post(f"/v2/outlets/{outlet['id']}/orders", headers=officer, json=body)
    assert first.status_code == 201 and first.json()["replayed"] is False
    assert second.json() == {"id": first.json()["id"], "status": "confirmed", "replayed": True}
    competitor = {"client_order_id": uuid.uuid4().hex, "lines": [{"product_id": ids["products"]["UNI-LUX-100"], "quantity": 1}]}
    assert client.post(f"/v2/outlets/{outlet['id']}/orders", headers=officer, json=competitor).status_code == 422


def test_call_brief_cites_sources(platform, officer):
    client = platform["client"]
    outlet = _outlet(client, officer, "S-104")
    client.post(f"/v2/outlets/{outlet['id']}/intelligence:refresh", headers=officer)
    brief = client.get(f"/v2/outlets/{outlet['id']}/call-brief", headers=officer).json()
    assert brief["talking_points"]
    assert all(point["citation"] for point in brief["talking_points"])
    assert any(point["kind"] == "promotion" for point in brief["talking_points"])


def test_human_classification_override_wins_and_keeps_system_view(platform, supervisor):
    client = platform["client"]
    outlet = _outlet(client, supervisor, "S-104")
    classes = client.get("/v2/catalog/outlet-classes", headers=supervisor).json()["classes"]
    target = next(c for c in classes if c["code"] == "A")
    response = client.post(f"/v2/outlets/{outlet['id']}/classification", headers=supervisor,
                           json={"class_id": target["id"], "note": "Recently expanded shop"})
    assert response.status_code == 201
    intel = client.post(f"/v2/outlets/{outlet['id']}/intelligence:refresh", headers=supervisor).json()
    assert intel["classification"]["source"] == "human"
    assert intel["classification"]["code"] == "A"
    assert intel["classification"]["system_assessment"]["source"] == "rule"


# --- capture → inference → review → measurements ------------------------------------------------


def test_shelf_audit_end_to_end(platform, officer, scripted_provider, ids):
    client = platform["client"]
    outlet = _outlet(client, officer, "S-101")  # Super Shop (Modern Trade)
    visit = client.post("/v2/visits", headers=officer, json={
        "client_visit_id": uuid.uuid4().hex, "outlet_id": outlet["id"], "lat": 23.79385, "lng": 90.40672}).json()
    assert visit["location_warning"] is False
    capture_id = uuid.uuid4().hex
    files = {"image": ("shelf.jpg", shelf_jpeg(1), "image/jpeg")}
    data = {"client_capture_id": capture_id, "area": "Soap bay"}
    first = client.post(f"/v2/visits/{visit['id']}/captures", headers=officer, files=files, data=data)
    assert first.status_code == 201, first.text
    replay = client.post(f"/v2/visits/{visit['id']}/captures", headers=officer,
                         files={"image": ("shelf.jpg", shelf_jpeg(1), "image/jpeg")}, data=data)
    assert replay.status_code == 200 and replay.json()["id"] == first.json()["id"]
    dup = client.post(f"/v2/visits/{visit['id']}/captures", headers=officer,
                      files={"image": ("again.jpg", shelf_jpeg(1), "image/jpeg")},
                      data={"client_capture_id": uuid.uuid4().hex})
    assert dup.json()["duplicate_of"] == first.json()["id"]

    assert client.post(f"/v2/visits/{visit['id']}/submit", headers=officer).status_code == 409  # still analysing
    jobs.drain(db.session_factory())
    assert scripted_provider.calls == 1  # duplicate not analysed

    capture = client.get(f"/v2/captures/{first.json()['id']}", headers=officer).json()
    assert capture["status"] == "analysed"
    assert capture["inference"]["model"]["provider"] == "scripted"
    detections = capture["detections"]
    assert len(detections) == 9
    assert {d["shelf_row"] for d in detections} == {1, 2, 3}
    flagged = [d for d in detections if d["needs_review"]]
    assert len(flagged) == 2  # unknown, low confidence

    visit_view = client.get(f"/v2/visits/{visit['id']}", headers=officer).json()
    share = next(m for m in visit_view["measurements"] if m["metric"] == "share_of_shelf" and m["basis"] == "all")
    assert share["value"] == round(3 / 9, 4)
    assert share["range"] == [round(3 / 9, 4), round(5 / 9, 4)]

    # Human review: one unknown is actually Meril (own), the other is not a product.
    review = client.post(f"/v2/detections/{flagged[0]['id']}/review", headers=officer,
                         json={"action": "correct", "product_id": ids["products"]["SQ-MER-SOAP-100"], "reason": "logo hidden"})
    assert review.status_code == 200, review.text
    assert review.json()["verification"] == "corrected"
    assert review.json()["predicted"]["label"] == "unknown"  # prediction preserved
    client.post(f"/v2/detections/{flagged[1]['id']}/review", headers=officer, json={"action": "reject"})
    for d in detections:
        if not d["needs_review"]:
            client.post(f"/v2/detections/{d['id']}/review", headers=officer, json={"action": "confirm"})
    visit_view = client.get(f"/v2/visits/{visit['id']}", headers=officer).json()
    verified = next(m for m in visit_view["measurements"] if m["metric"] == "share_of_shelf" and m["basis"] == "verified")
    assert verified["value"] == 0.5 and verified["denominator"] == 8

    with db.session_factory()() as session:
        correction = session.execute(select(RecognitionCorrection).where(
            RecognitionCorrection.detected_object_id == flagged[0]["id"])).scalar_one()
        assert correction.previous_label == "unknown" and correction.new_label == "own"
        assert correction.model_version_id == capture["inference"]["model"]["version_id"]

    submitted = client.post(f"/v2/visits/{visit['id']}/submit", headers=officer)
    assert submitted.status_code == 200, submitted.text
    intel = submitted.json()["intelligence"]
    assert intel["shelf"]["verified"]["share_of_shelf"] == 0.5
    results = {r["description"]: r for r in intel["placement"]["results"]}
    block = results["Square skin-cleansing block at eye level, ≥8 facings, ≥35% of shelf"]
    assert block["status"] == "non_compliant"  # 4 own facings < 8
    meril = results["Meril 100g at eye level with ≥3 facings"]
    assert meril["status"] == "non_compliant" and meril["observed"]["facings"] == 2
    types = {r["type"] for r in intel["recommendations"]}
    assert "increase_facings" in types
    dims = {s["dimension"]: s for s in intel["scores"]}
    assert dims["share_of_shelf"]["value"] is not None
    assert dims["placement"]["value"] is not None

    ai = client.get("/v2/analytics/ai", headers=login(client, "TO-2001")).json()
    stats = next(iter(m for m in ai["models"].values() if m["provider"] == "scripted"))
    assert stats["reviewed"] == 9 and stats["flagged_for_review"] == 2


def test_rejects_non_image_upload(platform, officer):
    client = platform["client"]
    outlet = _outlet(client, officer, "S-102")
    visit = client.post("/v2/visits", headers=officer, json={"client_visit_id": uuid.uuid4().hex, "outlet_id": outlet["id"]}).json()
    response = client.post(f"/v2/visits/{visit['id']}/captures", headers=officer,
                           files={"image": ("x.txt", b"not an image", "text/plain")},
                           data={"client_capture_id": uuid.uuid4().hex})
    assert response.status_code == 422


def test_only_visit_owner_uploads(platform, officer, supervisor):
    client = platform["client"]
    outlet = _outlet(client, officer, "S-102")
    visit = client.post("/v2/visits", headers=officer, json={"client_visit_id": uuid.uuid4().hex, "outlet_id": outlet["id"]}).json()
    response = client.post(f"/v2/visits/{visit['id']}/captures", headers=supervisor,
                           files={"image": ("s.jpg", shelf_jpeg(7), "image/jpeg")},
                           data={"client_capture_id": uuid.uuid4().hex})
    assert response.status_code == 403


# --- dashboards ----------------------------------------------------------------------------------


def test_dashboards_are_scoped(platform, supervisor):
    client = platform["client"]
    manager = login(client, "MG-4001")
    team = client.get("/v2/analytics/overview?group_by=territory", headers=supervisor).json()
    everyone = client.get("/v2/analytics/overview?group_by=territory", headers=manager).json()
    assert {g["label"] for g in team["groups"]} == {"Banani–Gulshan", "Mirpur"}
    assert len(everyone["groups"]) == 4
    brands = client.get("/v2/analytics/brands?channel=MT", headers=manager).json()
    assert brands["brands"] and all(0 <= b["numeric_distribution"] <= 1 for b in brands["brands"])
    funnel = client.get("/v2/analytics/recommendations", headers=manager).json()
    assert funnel["by_type"]


# --- configuration ---------------------------------------------------------------------------------


def test_rule_versioning_and_audit(platform, admin, ids):
    client = platform["client"]
    channels = {c["code"]: c["id"] for c in client.get("/v2/catalog/channels", headers=admin).json()}
    body = {"kind": "assortment", "name": "Core assortment v2", "items": [
        {"channel_id": channels["PH"], "product_id": ids["products"]["SQ-SEP-HW-200"], "min_facings": 3, "priority": 1}]}
    draft = client.post("/v2/admin/rule-sets", headers=admin, json=body).json()
    assert draft["version"] == 2 and draft["status"] == "draft"
    activated = client.post(f"/v2/admin/rule-sets/{draft['id']}/activate", headers=admin).json()
    assert len(activated["retired"]) == 1
    sets = client.get("/v2/admin/rule-sets?kind=assortment", headers=admin).json()
    assert [s["status"] for s in sets] == ["retired", "active"]
    bad = dict(body, items=[{"channel_id": "not-a-channel", "product_id": ids["products"]["SQ-SEP-HW-200"]}])
    assert client.post("/v2/admin/rule-sets", headers=admin, json=bad).status_code == 422
    with db.session_factory()() as session:
        actions = set(session.execute(select(AuditLog.action)).scalars())
    assert {"rules.create_draft", "rules.activate", "auth.login"} <= actions
    # Restore v1 so other tests keep their expectations.
    client.post(f"/v2/admin/rule-sets/{activated['retired'][0]}/activate", headers=admin)


def test_order_import_validates_every_row(platform, admin):
    client = platform["client"]
    with db.session_factory()() as session:
        outlet = session.execute(select(Outlet).where(Outlet.code == "S-104")).scalar_one()
    csv_text = (
        "external_ref,outlet_code,order_date,sku,quantity,unit_price\n"
        f"IMP-1,{outlet.code},2026-09-01,SQ-MER-SOAP-100,10,39.6\n"
        f"IMP-1,{outlet.code},2026-09-01,SQ-JUI-OIL-100,5,61.6\n"
        f"IMP-2,{outlet.code},2026-09-02,UNI-LUX-100,5,44\n"
        f"IMP-3,NOPE,2026-09-02,SQ-MER-SOAP-100,5,39.6\n"
    )
    files = {"file": ("orders.csv", csv_text.encode(), "text/csv")}
    result = client.post("/v2/admin/import/orders", headers=admin, files=files).json()
    assert result["orders_created"] == 1 and result["errors_total"] == 2
    again = client.post("/v2/admin/import/orders", headers=admin, files={"file": ("orders.csv", csv_text.encode(), "text/csv")}).json()
    assert again["orders_created"] == 0 and again["orders_skipped_existing"] == 1


def test_visit_history_is_scoped(platform, officer):
    client = platform["client"]
    karim = login(client, "SO-1042")
    mine = client.get("/v2/visits", headers=officer).json()
    assert mine and all(v["user_id"] == mine[0]["user_id"] for v in mine)
    assert client.get("/v2/visits", headers=karim).json() == []

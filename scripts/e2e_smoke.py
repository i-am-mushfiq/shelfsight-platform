"""End-to-end smoke test against a RUNNING server, following the field app's call sequence.

    python scripts/e2e_smoke.py [base_url]

Uses the synthetic demo organization and the real configured vision provider.
"""

from __future__ import annotations

import sys
import time
import uuid
from pathlib import Path

import httpx

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8765"
IMAGE = Path(__file__).resolve().parent.parent / "test_assets" / "shelf-square-high-6-of-12.png"


def main() -> None:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")  # Windows consoles default to cp1252
    client = httpx.Client(base_url=BASE, timeout=120)

    def step(name: str, response: httpx.Response) -> dict | list:
        if response.status_code >= 300:
            sys.exit(f"FAIL {name}: {response.status_code} {response.text[:300]}")
        print(f"ok   {name}")
        return response.json()

    login = step("login SO-1001", client.post("/v2/auth/login", json={"employee_id": "SO-1001", "password": "shelf123"}))
    client.headers["Authorization"] = f"Bearer {login['access_token']}"
    outlets = step("outlets", client.get("/v2/outlets"))
    outlet = next(o for o in outlets if o["code"] == "S-101")
    intel = step("intelligence", client.post(f"/v2/outlets/{outlet['id']}/intelligence:refresh"))
    print(f"     class={intel['classification']['label']} recs={len(intel['recommendations'])} origin={intel['data_origin']}")

    store_types = step("store types", client.get("/v2/catalog/store-types"))
    print(f"     {len(store_types)} store types: {', '.join(t['name'] for t in store_types)}")
    by_code = {t["code"]: t for t in store_types}
    new_shop = step("register shop", client.post("/v2/outlets", json={
        "client_outlet_id": uuid.uuid4().hex, "name": "Smoke Test Cosmetics", "store_type_id": by_code["GT-GROC"]["id"],
        "lat": outlet["lat"] + 0.002, "lng": outlet["lng"]}))
    print(f"     {new_shop['code']} verified={new_shop['is_verified']} duplicates={len(new_shop['possible_duplicates'])}")

    category = next(c for c in step("categories", client.get("/v2/catalog/categories")) if c["code"] == "SKIN")
    visit = step("start visit as Super Shop", client.post("/v2/visits", json={
        "client_visit_id": uuid.uuid4().hex, "outlet_id": outlet["id"], "lat": outlet["lat"], "lng": outlet["lng"],
        "store_type_id": by_code["MT-SS"]["id"]}))
    print(f"     store type={visit['store_type']['name']} changed_from={visit['previous_store_type']}")
    capture = step("upload photo", client.post(
        f"/v2/visits/{visit['id']}/captures",
        files={"image": (IMAGE.name, IMAGE.read_bytes(), "image/png")},
        data={"client_capture_id": uuid.uuid4().hex, "area": category["name"], "category_id": category["id"]}))
    print(f"     quality acceptable={capture['quality_acceptable']} warnings={capture['quality']['warnings']}")

    for _ in range(120):
        capture = client.get(f"/v2/captures/{capture['id']}").json()
        if capture["status"] in {"analysed", "failed"}:
            break
        time.sleep(1)
    if capture["status"] != "analysed":
        sys.exit(f"FAIL analysis: {capture['status']} {capture.get('inference')}")
    inference = capture["inference"]
    print(f"ok   analysed by {inference['model']['provider']} {inference['model']['version']} in "
          f"{inference['latency_ms']} ms: {inference['detections_total']} facings, {inference['needs_review']} need review")
    image = client.get(capture["image_url"])
    if image.status_code != 200 or not image.content:
        sys.exit(f"FAIL capture image: {image.status_code}")
    print(f"ok   capture image ({len(image.content)} bytes, authorised)")

    for detection in capture["detections"]:
        if detection["needs_review"]:
            step("review (correct to competitor)", client.post(
                f"/v2/detections/{detection['id']}/review", json={"action": "correct", "label": "competitor"}))
        else:
            step("review (confirm)", client.post(f"/v2/detections/{detection['id']}/review", json={"action": "confirm"}))

    result = step("submit visit", client.post(f"/v2/visits/{visit['id']}/submit"))
    shelf = result["intelligence"]["shelf"]["verified"]
    print(f"     verified share of shelf={shelf['share_of_shelf']} ({shelf['own_facings']}/{shelf['total_facings']})")
    for rule in result["intelligence"]["placement"]["results"]:
        print(f"     placement: {rule['status']:<14} {rule['description']}")
    order = result["order"]
    if order is None:
        sys.exit("FAIL no automatic order")
    print(f"ok   automatic order {order['status']}: {len(order['lines'])} lines, BDT {order['value']}")
    for line in order["lines"][:5]:
        print(f"       {line['name']} x{line['quantity']} - {'; '.join(line['reasons'])}")
    report = step("visit report", client.get(f"/v2/visits/{visit['id']}/report"))
    for text_line in report["summary_text"].splitlines():
        print(f"     | {text_line}")
    first = order["lines"][0]
    edited = step("edit order", client.put(f"/v2/orders/{order['id']}", json={
        "lines": [{"product_id": first["product_id"], "quantity": first["quantity"] + 1}]}))
    print(f"     edited: {edited['lines'][0]['quantity']} (suggested {edited['lines'][0]['suggested_quantity']})")

    suggestion = step("suggested order", client.get(f"/v2/outlets/{outlet['id']}/suggested-order"))
    line = suggestion["lines"][0]
    step("place order", client.post(f"/v2/outlets/{outlet['id']}/orders", json={
        "client_order_id": uuid.uuid4().hex,
        "lines": [{"product_id": line["product_id"], "quantity": line["quantity"], "suggested_quantity": line["quantity"]}]}))
    brief = step("call brief", client.get(f"/v2/outlets/{outlet['id']}/call-brief"))
    print(f"     {len(brief['talking_points'])} talking points")
    step("visit history", client.get("/v2/visits"))

    supervisor = step("login TO-2001", httpx.post(f"{BASE}/v2/auth/login", json={"employee_id": "TO-2001", "password": "shelf123"}, timeout=60))
    headers = {"Authorization": f"Bearer {supervisor['access_token']}"}
    overview = step("overview", client.get("/v2/analytics/overview", headers=headers))
    competition = step("competition", client.get("/v2/analytics/competition", headers=headers))
    step("ai quality", client.get("/v2/analytics/ai", headers=headers))
    print(f"     territories={[g['label'] for g in overview['groups']]} audited={competition['outlets_audited']}")
    print("ALL STEPS PASSED")


if __name__ == "__main__":
    main()

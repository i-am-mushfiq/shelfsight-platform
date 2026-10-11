r"""Creates the demo data the app-map screenshots show, on a running server, and writes
app_map/fixture.json. Run: .venv\Scripts\python.exe app_map\make_fixture.py http://127.0.0.1:8000"""
import json, sys, time, uuid
from pathlib import Path

import cv2
import httpx

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8000"
HERE = Path(__file__).parent
c = httpx.Client(base_url=BASE, timeout=300)
c.headers["Authorization"] = "Bearer " + c.post("/v2/auth/login", json={"employee_id": "SO-1001", "password": "shelf123"}).json()["access_token"]
outlets = c.get("/v2/outlets").json()
outlet = next(o for o in outlets if o["code"] == "S-104")
types = c.get("/v2/catalog/store-types").json()
store_type = next(t for t in types if t["code"] == "MT-SS")


def visit():
    return c.post("/v2/visits", json={"client_visit_id": uuid.uuid4().hex, "outlet_id": outlet["id"],
                                      "store_type_id": store_type["id"]}).json()


def upload(visit_id, name):
    r = c.post(f"/v2/visits/{visit_id}/captures", files={"image": (name, (HERE / name).read_bytes(), "image/jpeg")},
               data={"client_capture_id": uuid.uuid4().hex})
    r.raise_for_status()
    return r.json()["id"]


def wait(capture_id):
    for _ in range(180):
        cap = c.get(f"/v2/captures/{capture_id}").json()
        if cap["status"] in ("analysed", "failed"):
            return cap
        time.sleep(1)
    raise RuntimeError("analysis timed out")


a = visit()
caps_a = [upload(a["id"], n) for n in ("shelf_a.jpg", "shelf_b.jpg")]
for cid in caps_a:
    print("A", wait(cid)["status"])
report = c.post(f"/v2/visits/{a['id']}/submit").json()
b = visit()
caps_b = [upload(b["id"], "shelf_a.jpg")]
print("B", wait(caps_b[0])["status"])
# A 360° sphere: overlapping slices of a wide shelf image, as turning on the spot would give.
wide = cv2.imread(str(HERE / "shelf_a.jpg"))
wide = cv2.resize(wide, (3200, int(3200 * wide.shape[0] / wide.shape[1])))
frames = [wide[:, x:x + 900] for x in range(0, 2400, 400)]
files = [("frames", (f"f{i}.jpg", cv2.imencode(".jpg", f)[1].tobytes(), "image/jpeg")) for i, f in enumerate(frames)]
sphere = c.post(f"/v2/visits/{b['id']}/spheres", files=files,
                data={"client_capture_id": uuid.uuid4().hex, "yaws": json.dumps([i * 30 for i in range(len(frames))])})
sphere.raise_for_status()
sphere_capture = wait(sphere.json()["id"])
print("sphere", sphere_capture["status"], sphere_capture.get("sphere"))
c3 = visit()
fixture = {"outlet": outlet, "store_type": store_type, "visit_report": a["id"], "report_order": report.get("order"),
           "review_visit": b["id"], "review_captures": caps_b, "sphere_capture": sphere_capture,
           "capture_visit": c3["id"]}
(HERE / "fixture.json").write_text(json.dumps(fixture, indent=1))
print("order", (report.get("order") or {}).get("status"), "fixture written")

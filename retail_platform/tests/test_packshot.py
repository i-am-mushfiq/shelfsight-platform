"""Pack-shot lookup, live detection, photo spheres and the Square Food catalogue import.

Pack shots here are generated (textured labels with text), so the tests do not depend on the
scraped catalogue, which is not part of the repository.
"""

from __future__ import annotations

import csv
import json
import struct
import uuid

import cv2
import numpy as np
import pytest
from sqlalchemy import select

from retail_platform import db, jobs
from retail_platform.models import Manufacturer, Organization, Product, ReferenceImage
from retail_platform.vision import registry
from retail_platform.vision.imaging import decode_upright, exif_orientation
from retail_platform.vision.packshot_matcher import PackshotIndex, split_packs
from retail_platform.vision.sphere import stitch

from .conftest import login, shelf_jpeg


def pack_shot(seed: int, size=(420, 300), transparent: bool = False) -> np.ndarray:
    """A label-like image with enough structure for local features."""
    rng = np.random.default_rng(seed)
    h, w = size
    image = np.full((h, w, 3), rng.integers(30, 220, 3), np.uint8)
    for _ in range(40):
        colour = tuple(int(c) for c in rng.integers(0, 255, 3))
        x, y = int(rng.integers(0, w)), int(rng.integers(0, h))
        kind = rng.integers(0, 3)
        if kind == 0:
            cv2.circle(image, (x, y), int(rng.integers(5, 40)), colour, -1)
        elif kind == 1:
            cv2.rectangle(image, (x, y), (x + int(rng.integers(10, 80)), y + int(rng.integers(10, 60))), colour, -1)
        else:
            cv2.putText(image, f"P{seed}{x % 97}", (x, y), cv2.FONT_HERSHEY_SIMPLEX, 0.6 + rng.random(), colour, 2)
    if transparent:
        canvas = np.zeros((h + 80, w + 80, 4), np.uint8)
        canvas[40:40 + h, 40:40 + w, :3] = image
        canvas[40:40 + h, 40:40 + w, 3] = 255
        return canvas
    canvas = np.full((h + 80, w + 80, 3), 255, np.uint8)
    canvas[40:40 + h, 40:40 + w] = image
    return canvas


def png(image: np.ndarray) -> bytes:
    return cv2.imencode(".png", image)[1].tobytes()


def scene(packs: dict[str, np.ndarray], width=1600, height=1100, seed=0) -> tuple[np.ndarray, dict[str, tuple]]:
    """Shelf-like background with each pack pasted once, slightly warped, darker and blurred."""
    rng = np.random.default_rng(seed)
    canvas = rng.integers(60, 120, (height, width, 3), dtype=np.uint8)
    canvas = cv2.GaussianBlur(canvas, (31, 31), 0)
    truth = {}
    for i, (product_id, image) in enumerate(packs.items()):
        label = image[40:-40, 40:-40, :3]
        scale = 0.7 + 0.1 * i
        label = cv2.resize(label, None, fx=scale, fy=scale)
        h, w = label.shape[:2]
        shift = 0.05 * w
        warp = cv2.getPerspectiveTransform(np.float32([[0, 0], [w, 0], [w, h], [0, h]]),
                                           np.float32([[shift, 0], [w, shift], [w - shift, h], [0, h - shift]]))
        label = cv2.warpPerspective(label, warp, (w, h), borderValue=(90, 90, 90))
        x0, y0 = 80 + i * 480, 120 + (i % 2) * 400
        canvas[y0:y0 + h, x0:x0 + w] = label
        truth[product_id] = (x0 / width, y0 / height, w / width, h / height)
    canvas = cv2.convertScaleAbs(canvas, alpha=0.85, beta=10)
    return cv2.GaussianBlur(canvas, (3, 3), 0), truth


def iou(a, b) -> float:  # type: ignore[no-untyped-def]
    ix = max(0.0, min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0]))
    iy = max(0.0, min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1]))
    inter = ix * iy
    return inter / (a[2] * a[3] + b[2] * b[3] - inter)


# --- matcher -----------------------------------------------------------------------------------------

def test_index_finds_each_pack_where_it_is_and_nothing_on_an_empty_shelf():
    shots = {f"p{i}": pack_shot(i, transparent=i % 2 == 0) for i in range(3)}
    index = PackshotIndex([(pid, png(img)) for pid, img in shots.items()] + [("p9", png(pack_shot(9)))])
    image, truth = scene(shots)
    found = {m.product_id: m for m in index.match(image)}
    assert set(found) == set(truth)  # p9 is not on the shelf
    for product_id, box in truth.items():
        assert iou(found[product_id].box, box) > 0.6
        assert 0 < found[product_id].confidence <= 0.99 and found[product_id].inliers >= 9
    empty = cv2.GaussianBlur(np.random.default_rng(5).integers(60, 120, (1100, 1600, 3), dtype=np.uint8), (31, 31), 0)
    assert index.match(empty) == []


def test_repeated_facings_of_one_product_are_all_found():
    shot = pack_shot(4)
    index = PackshotIndex([("p4", png(shot))])
    image, _ = scene({"a": shot, "b": shot.copy(), "c": shot.copy()}, seed=2)
    assert [m.product_id for m in index.match(image)] == ["p4"] * 3


def test_group_pack_shots_are_split_into_single_packs():
    group = np.full((500, 900, 3), 255, np.uint8)
    group[50:450, 40:380] = pack_shot(1)[40:440, 40:380]
    group[50:450, 500:840] = pack_shot(2)[40:440, 40:380]
    crops = split_packs(png(group))
    assert len(crops) == 2 and all(c.shape[1] < 450 for c in crops)
    touching = pack_shot(3)
    assert len(split_packs(png(touching))) == 1


def test_wide_panoramas_are_searched_in_tiles():
    shots = {f"p{i}": pack_shot(20 + i) for i in range(3)}
    image, truth = scene(shots, width=4200, height=1000, seed=4)
    image[:, 3000:] = image[:, 3000:]  # packs are spread across a panorama much wider than tall
    index = PackshotIndex([(pid, png(img)) for pid, img in shots.items()])
    assert {m.product_id for m in index.match(image)} == set(truth)


# --- images and spheres ------------------------------------------------------------------------------

def _with_orientation(jpeg: bytes, orientation: int) -> bytes:
    tiff = b"II*\x00" + struct.pack("<I", 8) + struct.pack("<H", 1) + \
        struct.pack("<HHIHH", 0x0112, 3, 1, orientation, 0) + struct.pack("<I", 0)
    app1 = b"Exif\x00\x00" + tiff
    return jpeg[:2] + b"\xff\xe1" + struct.pack(">H", len(app1) + 2) + app1 + jpeg[2:]


def test_phone_photos_are_turned_upright_once():
    image = np.zeros((100, 200, 3), np.uint8)
    image[:, :20] = 255  # white strip on the left edge
    jpeg = cv2.imencode(".jpg", image)[1].tobytes()
    rotated = _with_orientation(jpeg, 6)
    assert exif_orientation(rotated) == 6 and exif_orientation(jpeg) == 1
    upright = decode_upright(rotated)
    assert upright.shape[:2] == (200, 100)
    assert upright[:20].mean() > 200  # the left strip is now on top (rotated 90° clockwise)
    assert decode_upright(b"not an image") is None


def test_sphere_stitches_overlapping_frames_or_falls_back_side_by_side():
    rng = np.random.default_rng(1)
    world = cv2.GaussianBlur(rng.integers(0, 255, (700, 3600, 3), dtype=np.uint8), (5, 5), 0)
    for i in range(60):
        cv2.putText(world, f"SHELF {i}", (60 * i, 100 + (i % 9) * 60), cv2.FONT_HERSHEY_SIMPLEX, 1.5, (255, 255, 0), 3)
    frames = [world[:, x:x + 900].copy() for x in range(0, 2700, 450)]
    yaws = [i * 30.0 for i in range(len(frames))]
    result = stitch(list(reversed(frames)), list(reversed(yaws)))  # order comes from the yaws
    assert result.frames == 6 and result.yaw_span == 150.0
    assert result.horizontal_degrees == 210.0
    assert result.image.shape[1] > 1.5 * result.image.shape[0]
    assert result.metadata()["kind"] == "sphere"
    flat = [np.full((500, 400, 3), 128, np.uint8) for _ in range(3)]  # nothing to match: side by side
    fallback = stitch(flat, None)
    assert fallback.stitched is False and fallback.image.shape[1] == 1200 and fallback.note


# --- API ---------------------------------------------------------------------------------------------

@pytest.fixture
def pack_shots(platform, admin, ids):
    """Pack shots for two own products and one competitor product, uploaded through the admin API."""
    client = platform["client"]
    mapping = {"SQ-JUI-OIL-100": pack_shot(31), "SQ-CHK-DET-500": pack_shot(32, transparent=True),
               "UNI-WHL-500": pack_shot(33)}
    uploaded = []
    for sku, image in mapping.items():
        response = client.post(f"/v2/admin/products/{ids['products'][sku]}/reference-images", headers=admin,
                               files={"image": (f"{sku}.png", png(image), "image/png")})
        assert response.status_code in (200, 201), response.text
        uploaded.append(response.json()["id"])
    yield mapping
    for image_id in uploaded:
        client.delete(f"/v2/admin/reference-images/{image_id}", headers=admin)


def test_live_detection_names_products_and_confidence(platform, officer, pack_shots, ids):
    client = platform["client"]
    image, truth = scene(pack_shots, seed=7)
    frame = cv2.imencode(".jpg", image, [int(cv2.IMWRITE_JPEG_QUALITY), 85])[1].tobytes()
    response = client.post("/v2/live/detect", headers=officer, files={"frame": ("f.jpg", frame, "image/jpeg")})
    assert response.status_code == 200, response.text
    body = response.json()
    by_sku = {d["sku"]: d for d in body["detections"]}
    assert set(by_sku) == set(truth)
    assert by_sku["SQ-JUI-OIL-100"]["is_own"] is True and by_sku["UNI-WHL-500"]["is_own"] is False
    assert by_sku["SQ-JUI-OIL-100"]["name"] == "Jui Coconut Oil 100ml" and by_sku["SQ-JUI-OIL-100"]["confidence"] > 0.3
    assert iou(tuple(by_sku["SQ-CHK-DET-500"]["box"].values()), truth["SQ-CHK-DET-500"]) > 0.6
    assert body["summary"]["own_facings"] == 2 and body["index"]["products"] >= 3  # other tests add pack shots too
    assert (body["width"], body["height"]) == (1600, 1100)
    bad = client.post("/v2/live/detect", headers=officer, files={"frame": ("x.jpg", b"nope", "image/jpeg")})
    assert bad.status_code == 422
    manager = login(client, "MG-4001")
    assert client.post("/v2/live/detect", headers=manager,
                       files={"frame": ("f.jpg", frame, "image/jpeg")}).status_code == 403


def test_saved_photos_use_the_lookup_and_keep_other_facings_unidentified(platform, officer, pack_shots, ids):
    from retail_platform.vision.opencv_baseline import OpenCvBaselineProvider
    from retail_platform.vision.packshot_matcher import PackshotMatchProvider

    client = platform["client"]
    registry.set_provider(PackshotMatchProvider(OpenCvBaselineProvider()))
    try:
        outlets = client.get("/v2/outlets", headers=officer).json()
        visit = client.post("/v2/visits", headers=officer, json={
            "client_visit_id": uuid.uuid4().hex, "outlet_id": outlets[0]["id"]}).json()
        image, truth = scene(pack_shots, seed=8)
        upload = client.post(f"/v2/visits/{visit['id']}/captures", headers=officer,
                             files={"image": ("s.jpg", cv2.imencode(".jpg", image)[1].tobytes(), "image/jpeg")},
                             data={"client_capture_id": uuid.uuid4().hex})
        jobs.drain(db.session_factory())
        capture = client.get(f"/v2/captures/{upload.json()['id']}", headers=officer).json()
    finally:
        registry.set_provider(None)
    assert capture["inference"]["model"]["provider"] == "packshot-match"
    identified = {d["final"]["product_id"] for d in capture["detections"] if d["final"]["product_id"]}
    assert identified == {ids["products"][sku] for sku in truth}
    assert all(d["final"]["label"] == "unknown" for d in capture["detections"] if not d["final"]["product_id"])
    assert capture["inference"]["annotated_url"]


def test_sphere_upload_becomes_one_analysed_capture(platform, officer, scripted_provider):
    client = platform["client"]
    outlets = client.get("/v2/outlets", headers=officer).json()
    visit = client.post("/v2/visits", headers=officer, json={
        "client_visit_id": uuid.uuid4().hex, "outlet_id": outlets[1]["id"]}).json()
    world = cv2.GaussianBlur(np.random.default_rng(3).integers(0, 255, (600, 2400, 3), dtype=np.uint8), (5, 5), 0)
    frames = [cv2.imencode(".jpg", world[:, x:x + 800])[1].tobytes() for x in range(0, 1700, 400)]
    client_id = uuid.uuid4().hex
    files = [("frames", (f"f{i}.jpg", f, "image/jpeg")) for i, f in enumerate(frames)]
    data = {"client_capture_id": client_id, "yaws": json.dumps([i * 30 for i in range(len(frames))])}
    first = client.post(f"/v2/visits/{visit['id']}/spheres", headers=officer, files=files, data=data)
    assert first.status_code == 201, first.text
    body = first.json()
    assert body["kind"] == "sphere" and body["sphere"]["frames"] == 5 and body["sphere"]["yaw_span"] == 120.0
    assert body["width"] > body["height"]
    again = client.post(f"/v2/visits/{visit['id']}/spheres", headers=officer, files=files, data=data)
    assert again.status_code == 200 and again.json()["id"] == body["id"]
    jobs.drain(db.session_factory())
    assert client.get(f"/v2/captures/{body['id']}", headers=officer).json()["status"] == "analysed"
    one = client.post(f"/v2/visits/{visit['id']}/spheres", headers=officer, files=files[:1],
                      data={"client_capture_id": uuid.uuid4().hex})
    assert one.status_code == 422


def test_square_food_catalogue_import(platform, tmp_path):
    from retail_platform.services.sfbl_import import import_catalog

    root = tmp_path / "sfbl"
    (root / "products" / "radhuni").mkdir(parents=True)
    cv2.imwrite(str(root / "products" / "radhuni" / "001_turmeric.png"), pack_shot(41, transparent=True))
    cv2.imwrite(str(root / "products" / "radhuni" / "001_turmeric_desc1.jpg"), pack_shot(42))
    fields = ["pid", "brand", "category", "name", "available_in", "listed_on_brand_page", "local_images", "page_url"]
    with (root / "products.csv").open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerow({"pid": "1", "brand": "Radhuni", "category": "Basic Spices", "name": "Radhuni Turmeric Powder",
                         "available_in": "50 g", "listed_on_brand_page": "True", "page_url": "https://example/1",
                         "local_images": "products/radhuni/001_turmeric.png | products/radhuni/001_turmeric_desc1.jpg"})
        writer.writerow({"pid": "99", "brand": "Unlisted", "category": "", "name": "Old Snack",
                         "available_in": "", "listed_on_brand_page": "False", "page_url": "", "local_images": ""})
    with db.session_factory()() as session:
        org = session.get(Organization, platform["org_id"])
        first = import_catalog(session, org, root)
        session.commit()
        second = import_catalog(session, org, root)
        session.commit()
        maker = session.execute(select(Manufacturer).where(Manufacturer.code == "SFBL")).scalar_one()
        turmeric = session.execute(select(Product).where(Product.sku == "SFBL-001")).scalar_one()
        shots = session.execute(select(ReferenceImage).where(ReferenceImage.product_id == turmeric.id)).scalars().all()
    assert (first.products_created, first.pack_shots_added) == (2, 1)  # description artwork is not a pack shot
    assert first.products_without_pack_shot == ["Old Snack"]
    assert (second.products_created, second.products_updated, second.pack_shots_added) == (0, 2, 0)
    assert maker.is_own is True and turmeric.manufacturer_id == maker.id and len(shots) == 1

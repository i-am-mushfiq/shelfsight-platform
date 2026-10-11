"""Visual lookup (OWLv2 + CLIP) on the demo data. Needs PyTorch/transformers, the scraped Square
Food pack shots (datasets/sfbl_catalog) and the demo shelf images (FMCG_Shelf_Test_Set_20), none
of which are in the repository; skipped otherwise."""

from __future__ import annotations

import csv
import importlib.util
import re
from pathlib import Path

import cv2
import pytest

ROOT = Path(__file__).resolve().parents[2]
CATALOG_DIR = ROOT / "datasets" / "sfbl_catalog"
SHELVES = ROOT / "FMCG_Shelf_Test_Set_20"
pytestmark = pytest.mark.skipif(
    any(importlib.util.find_spec(m) is None for m in ("torch", "transformers"))
    or not (CATALOG_DIR / "products.csv").exists() or not SHELVES.exists(),
    reason="visual lookup needs PyTorch, transformers, datasets/sfbl_catalog and FMCG_Shelf_Test_Set_20",
)


@pytest.fixture(scope="module")
def lookup():  # type: ignore[no-untyped-def]
    from retail_platform.services.sfbl_import import DEMO_COMPETITOR_BRANDS
    from retail_platform.vision.base import CatalogEntry
    from retail_platform.vision.visual_lookup import VisualLookupProvider

    catalog = []
    for row in csv.DictReader(open(CATALOG_DIR / "products.csv", encoding="utf-8")):
        shots = []
        for name in (f.strip() for f in row["local_images"].split("|")):
            if name and "_desc" not in name:
                image = cv2.imread(str(CATALOG_DIR / name), cv2.IMREAD_COLOR)
                if image is not None:
                    shots.append(cv2.imencode(".jpg", image)[1].tobytes())
        brand = row["brand"] if row["brand"] != "Unlisted" else "Square Food (other)"
        catalog.append(CatalogEntry(row["pid"], row["pid"], row["name"], brand, "m-own", "Square Food & Beverage",
                                    True, row["category"], None, tuple(shots)))
    for brand in DEMO_COMPETITOR_BRANDS:
        catalog.append(CatalogEntry(f"c-{brand}", brand, f"{brand} (any product)", brand, f"m-{brand}", brand,
                                    False, "food", None, ()))
    return VisualLookupProvider(), catalog


def _own_share(lookup, path: Path) -> float:  # type: ignore[no-untyped-def]
    provider, catalog = lookup
    result = provider.analyze(path.read_bytes(), catalog, "m-own")
    own = sum(1 for d in result.detections if d.label == "own")
    return 100 * own / max(1, len(result.detections))


@pytest.mark.parametrize("name", ["supershop/shelf_01_80pct_own.png", "mudi_dokan/mudi_01_80pct_own.png",
                                  "competitor_heavy/sparse_05_supershop_target08pct.png",
                                  "competitor_heavy/sparse_08_mudi_target14pct.png"])
def test_share_of_shelf_tracks_the_scene(lookup, name):  # type: ignore[no-untyped-def]
    target = int(re.search(r"(\d+)pct", name).group(1))
    assert abs(_own_share(lookup, SHELVES / name) - target) <= 12


def test_competitor_brands_are_named_from_the_printed_name(lookup):  # type: ignore[no-untyped-def]
    provider, catalog = lookup
    result = provider.analyze((SHELVES / "competitor_heavy" / "sparse_01_supershop_target15pct.png").read_bytes(),
                              catalog, "m-own")
    named = {d.product_id for d in result.detections if d.evidence.get("method") == "brand"}
    assert {"c-ShadBari", "c-Jhalika"} <= named
    assert all(d.label == "competitor" for d in result.detections if d.evidence.get("method") == "brand")


# (file, seed, screen kind) as in the evaluation of 20 simulated screen photos.
SCREEN_CASES = [("competitor_heavy/sparse_01_supershop_target15pct.png", 0, "lcd"),
                ("competitor_heavy/sparse_05_supershop_target08pct.png", 4, "lcd"),
                ("mudi_dokan/mudi_02_65pct_own.png", 9, "lcd"),
                ("supershop/shelf_04_35pct_own.png", 17, "crt")]


@pytest.mark.parametrize("name,seed,kind", SCREEN_CASES)
def test_share_of_shelf_from_a_photo_of_a_screen(lookup, tmp_path, name, seed, kind):  # type: ignore[no-untyped-def]
    import numpy as np

    from retail_platform.tests.screen_sim import photograph_screen

    photo = photograph_screen(cv2.imread(str(SHELVES / name)), np.random.default_rng(seed), kind)
    path = tmp_path / "screen.jpg"
    cv2.imwrite(str(path), photo)
    target = int(re.search(r"(\d+)pct", name).group(1))
    assert abs(_own_share(lookup, path) - target) <= 12

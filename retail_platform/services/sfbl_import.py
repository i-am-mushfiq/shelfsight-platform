"""Load the scraped Square Food & Beverage catalogue (datasets/sfbl_catalog) into an organization:
manufacturer, brands, categories, one product per scraped product, and its pack shots as
reference images for the pack-shot matcher. Idempotent: re-running updates names and adds
only pack shots that are not there yet.

The website lists no prices, so these products carry no trade price and cannot be put on an
order until prices are loaded; they are recognised, counted and reported like any product.

For the demonstration it also adds the competitor brands that appear on the demo shelf images,
one placeholder product per brand ("Jhalika (any product)"). They have no pack shots: the visual
lookup recognises them by reading the brand name printed on the pack.
"""

from __future__ import annotations

import csv
import re
from dataclasses import dataclass, field
from pathlib import Path

from sqlalchemy import select
from sqlalchemy.orm import Session

from ..models import Brand, Category, Manufacturer, Organization, Product
from . import reference_images

MANUFACTURER_CODE = "SFBL"
MANUFACTURER_NAME = "Square Food & Beverage"
ROOT_CATEGORY = ("FOOD", "Food")
# Competitor brands seen on the demo shelf images (written in Latin script on their packs).
DEMO_COMPETITOR_BRANDS = ("ShadBari", "Jhalika", "Bhojona", "Moyna Bite", "NoboTaste", "Mawa", "MistiMela",
                          "RannaBari", "Tasty", "FreshUp", "Crunchy", "SunBite", "Purbani")


@dataclass(slots=True)
class ImportSummary:
    products_created: int = 0
    products_updated: int = 0
    pack_shots_added: int = 0
    pack_shots_present: int = 0
    products_without_pack_shot: list[str] = field(default_factory=list)
    rejected_images: list[str] = field(default_factory=list)
    competitor_brands_added: int = 0


def _slug(text: str) -> str:
    return re.sub(r"[^A-Z0-9]+", "-", text.upper()).strip("-")[:24] or "OTHER"


def import_catalog(session: Session, organization: Organization, root: Path) -> ImportSummary:
    rows = list(csv.DictReader((root / "products.csv").open(encoding="utf-8")))
    org, origin = organization.id, organization.data_origin
    summary = ImportSummary()

    def one(model, **where):  # type: ignore[no-untyped-def]
        return session.execute(select(model).filter_by(organization_id=org, **where)).scalar_one_or_none()

    manufacturer = one(Manufacturer, code=MANUFACTURER_CODE)
    if manufacturer is None:
        manufacturer = Manufacturer(organization_id=org, data_origin=origin, code=MANUFACTURER_CODE,
                                    name=MANUFACTURER_NAME, is_own=True)
        session.add(manufacturer)
        session.flush()
    food = one(Category, code=ROOT_CATEGORY[0])
    if food is None:
        food = Category(organization_id=org, data_origin=origin, code=ROOT_CATEGORY[0], name=ROOT_CATEGORY[1],
                        path=f"/{ROOT_CATEGORY[0].lower()}/", level=0)
        session.add(food)
        session.flush()
    brands: dict[str, Brand] = {}
    categories: dict[str, Category] = {}
    for row in rows:
        brand_name = row["brand"] if row["brand"] != "Unlisted" else "Square Food (other)"
        brand_code = f"SFBL-{_slug(brand_name)}"
        if brand_code not in brands:
            brands[brand_code] = one(Brand, code=brand_code) or Brand(
                organization_id=org, data_origin=origin, code=brand_code, name=brand_name,
                manufacturer_id=manufacturer.id)
            session.add(brands[brand_code])
        category_name = row["category"] or "Other"
        category_code = f"SFBL-{_slug(category_name)}"
        if category_code not in categories:
            categories[category_code] = one(Category, code=category_code) or Category(
                organization_id=org, data_origin=origin, code=category_code, name=category_name, parent_id=food.id,
                path=f"{food.path}{category_code.lower()}/", level=1)
            session.add(categories[category_code])
        session.flush()
        sku = f"SFBL-{int(row['pid']):03d}"
        product = one(Product, sku=sku)
        # Delisted products stay active: old stock is still on shelves and should be recognised.
        attributes = {"source": "sfbl.com.bd", "available_in": row["available_in"], "page_url": row["page_url"],
                      "listed_on_brand_page": row["listed_on_brand_page"] == "True"}
        if product is None:
            product = Product(organization_id=org, data_origin=origin, sku=sku, name=row["name"],
                              brand_id=brands[brand_code].id, manufacturer_id=manufacturer.id,
                              category_id=categories[category_code].id, attributes=attributes)
            session.add(product)
            session.flush()
            summary.products_created += 1
        else:
            product.name, product.attributes = row["name"], {**(product.attributes or {}), **attributes}
            summary.products_updated += 1
        files = [f.strip() for f in row["local_images"].split("|") if f.strip() and "_desc" not in f]
        if not files:
            summary.products_without_pack_shot.append(row["name"])
        for relative in files:
            path = root / relative
            try:
                result = reference_images.add_reference_image(session, org, origin, product, path.read_bytes(),
                                                              path.name, "front")
            except (OSError, reference_images.ReferenceImageRejected) as exc:
                summary.rejected_images.append(f"{relative}: {exc}")
                continue
            if result.created:
                summary.pack_shots_added += 1
            else:
                summary.pack_shots_present += 1
    summary.competitor_brands_added = _demo_competitors(session, organization, food)
    session.flush()
    return summary


def _demo_competitors(session: Session, organization: Organization, food: Category) -> int:
    org, origin = organization.id, organization.data_origin
    added = 0
    for name in DEMO_COMPETITOR_BRANDS:
        code = f"DEMO-{_slug(name)}"
        if session.execute(select(Product).filter_by(organization_id=org, sku=code)).scalar_one_or_none():
            continue
        manufacturer = Manufacturer(organization_id=org, data_origin=origin, code=code, name=name, is_own=False)
        session.add(manufacturer)
        session.flush()
        brand = Brand(organization_id=org, data_origin=origin, code=code, name=name, manufacturer_id=manufacturer.id)
        session.add(brand)
        session.flush()
        session.add(Product(organization_id=org, data_origin=origin, sku=code, name=f"{name} (any product)",
                            brand_id=brand.id, manufacturer_id=manufacturer.id, category_id=food.id,
                            attributes={"source": "demo", "placeholder": True}))
        added += 1
    return added

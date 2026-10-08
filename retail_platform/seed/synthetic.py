"""Deterministic SYNTHETIC demo dataset.

Everything created here lives in its own organization (slug ``demo-synthetic``) and every
row carries ``data_origin = "synthetic"``. Brand names are real market brands used only as
recognisable labels; every SKU, price, outlet, sales figure and rule is invented and must
not be read as market data.
"""

from __future__ import annotations

import math
import random
from dataclasses import dataclass
from datetime import date, timedelta

from sqlalchemy import select
from sqlalchemy.orm import Session

from ..models import (
    Brand,
    Category,
    Channel,
    ClassScheme,
    CompetitorObservation,
    CoreAssortmentItem,
    Distributor,
    Manufacturer,
    Order,
    OrderItem,
    Organization,
    Outlet,
    OutletAssignment,
    OutletClass,
    PlacementRule,
    PortfolioTarget,
    Product,
    ProductPrice,
    Promotion,
    PromotionProduct,
    Role,
    RuleSet,
    Territory,
    User,
)
from ..security import hash_password

SLUG = "demo-synthetic"
ORIGIN = "synthetic"
DEMO_PASSWORD = "shelf123"  # synthetic organization only

MANUFACTURERS = [
    ("SQ", "Square Toiletries", True),
    ("UNI", "Unilever Bangladesh", False),
    ("RB", "Reckitt Benckiser", False),
    ("KCL", "Kohinoor Chemical", False),
    ("ACI", "ACI Consumer", False),
    ("KEYA", "Keya Cosmetics", False),
    ("MAR", "Marico Bangladesh", False),
]

BRANDS = [
    ("MERIL", "Meril", "মেরিল", "SQ"), ("SEPNIL", "Sepnil", "সেপনিল", "SQ"), ("JUI", "Jui", "জুঁই", "SQ"),
    ("CHAKA", "Chaka", "চাকা", "SQ"),
    ("LUX", "Lux", None, "UNI"), ("LIFEBUOY", "Lifebuoy", None, "UNI"), ("DOVE", "Dove", None, "UNI"),
    ("SUNSILK", "Sunsilk", None, "UNI"), ("WHEEL", "Wheel", None, "UNI"), ("PEPSODENT", "Pepsodent", None, "UNI"),
    ("DETTOL", "Dettol", None, "RB"),
    ("TIBET", "Tibet", None, "KCL"),
    ("SAVLON", "Savlon", None, "ACI"),
    ("KEYA", "Keya", None, "KEYA"),
    ("PARACHUTE", "Parachute", None, "MAR"),
]

# code, name, parent
CATEGORIES = [
    ("PC", "Personal Care", None), ("SKIN", "Skin Cleansing", "PC"), ("BAR", "Bar Soap", "SKIN"),
    ("HW", "Hand Wash", "SKIN"), ("HAIR", "Hair Care", "PC"), ("OIL", "Hair Oil", "HAIR"),
    ("SHAMPOO", "Shampoo", "HAIR"), ("ORAL", "Oral Care", "PC"), ("PASTE", "Toothpaste", "ORAL"),
    ("HOME", "Home Care", None), ("LAUNDRY", "Laundry Detergent", "HOME"),
]

# sku, name, brand, category, pack, unit, tier, mrp, base weekly demand index
PRODUCTS = [
    ("SQ-MER-SOAP-100", "Meril Milk & Rose Soap 100g", "MERIL", "BAR", 100, "g", "mass", 45, 1.0),
    ("SQ-MER-SOAP-150", "Meril Milk & Kiwi Soap 150g", "MERIL", "BAR", 150, "g", "mass", 65, 0.6),
    ("SQ-MER-SHMP-180", "Meril Herbal Shampoo 180ml", "MERIL", "SHAMPOO", 180, "ml", "mass", 190, 0.25),
    ("SQ-SEP-HW-200", "Sepnil Hand Wash 200ml", "SEPNIL", "HW", 200, "ml", "mass", 110, 0.5),
    ("SQ-SEP-HW-RF-170", "Sepnil Hand Wash Refill 170ml", "SEPNIL", "HW", 170, "ml", "economy", 75, 0.35),
    ("SQ-JUI-OIL-100", "Jui Coconut Oil 100ml", "JUI", "OIL", 100, "ml", "mass", 70, 0.7),
    ("SQ-JUI-OIL-200", "Jui Coconut Oil 200ml", "JUI", "OIL", 200, "ml", "mass", 135, 0.4),
    ("SQ-CHK-DET-500", "Chaka Super White Detergent 500g", "CHAKA", "LAUNDRY", 500, "g", "economy", 70, 0.6),
    ("SQ-CHK-DET-1K", "Chaka Super White Detergent 1kg", "CHAKA", "LAUNDRY", 1000, "g", "economy", 135, 0.3),
    ("UNI-LUX-100", "Lux Soft Touch Soap 100g", "LUX", "BAR", 100, "g", "mass", 50, None),
    ("UNI-LUX-150", "Lux Velvet Glow Soap 150g", "LUX", "BAR", 150, "g", "mass", 70, None),
    ("UNI-LFB-100", "Lifebuoy Total Soap 100g", "LIFEBUOY", "BAR", 100, "g", "economy", 40, None),
    ("UNI-DOVE-100", "Dove Cream Beauty Bar 100g", "DOVE", "BAR", 100, "g", "premium", 120, None),
    ("UNI-LFB-HW-200", "Lifebuoy Hand Wash 200ml", "LIFEBUOY", "HW", 200, "ml", "mass", 105, None),
    ("UNI-SUN-180", "Sunsilk Shampoo 180ml", "SUNSILK", "SHAMPOO", 180, "ml", "mass", 210, None),
    ("UNI-WHL-500", "Wheel Detergent 500g", "WHEEL", "LAUNDRY", 500, "g", "economy", 65, None),
    ("UNI-PEP-100", "Pepsodent Toothpaste 100g", "PEPSODENT", "PASTE", 100, "g", "mass", 95, None),
    ("RB-DET-SOAP-75", "Dettol Original Soap 75g", "DETTOL", "BAR", 75, "g", "premium", 55, None),
    ("RB-DET-HW-200", "Dettol Hand Wash 200ml", "DETTOL", "HW", 200, "ml", "premium", 140, None),
    ("KCL-TIB-SOAP-100", "Tibet Beauty Soap 100g", "TIBET", "BAR", 100, "g", "economy", 35, None),
    ("KCL-TIB-OIL-200", "Tibet Coconut Oil 200ml", "TIBET", "OIL", 200, "ml", "economy", 120, None),
    ("ACI-SAV-SOAP-100", "Savlon Soap 100g", "SAVLON", "BAR", 100, "g", "mass", 45, None),
    ("ACI-SAV-HW-200", "Savlon Hand Wash 200ml", "SAVLON", "HW", 200, "ml", "mass", 100, None),
    ("KEYA-SOAP-100", "Keya Beauty Soap 100g", "KEYA", "BAR", 100, "g", "economy", 35, None),
    ("MAR-PAR-OIL-100", "Parachute Coconut Oil 100ml", "PARACHUTE", "OIL", 100, "ml", "mass", 80, None),
    ("MAR-PAR-OIL-200", "Parachute Coconut Oil 200ml", "PARACHUTE", "OIL", 200, "ml", "mass", 150, None),
]

# code, name, parent, Bangla
CHANNELS = [
    ("GT", "General Trade", None, "সাধারণ দোকান"),
    ("GT-GROC", "Grocery (Mudi)", "GT", "মুদি দোকান"),
    ("GT-COS", "Cosmetics Store", "GT", "কসমেটিকস"),
    ("MT", "Modern Trade", None, "আধুনিক দোকান"),
    ("MT-SS", "Super Shop", "MT", "সুপার শপ"),
    ("PH", "Pharmacy", None, "ফার্মেসি"),
    ("WS", "Wholesale", None, "পাইকারি"),
]

TERRITORIES = [
    ("BD", "Bangladesh", "country", None, None),
    ("DHK", "Dhaka Region", "region", "BD", None),
    ("DHK-N", "Dhaka North", "area", "DHK", None),
    ("T-BAN", "Banani–Gulshan", "territory", "DHK-N", (23.7937, 90.4066)),
    ("T-MIR", "Mirpur", "territory", "DHK-N", (23.8069, 90.3687)),
    ("DHK-S", "Dhaka South", "area", "DHK", None),
    ("T-DHN", "Dhanmondi", "territory", "DHK-S", (23.7461, 90.3742)),
    ("CTG", "Chattogram Region", "region", "BD", None),
    ("CTG-C", "Chattogram City", "area", "CTG", None),
    ("T-AGR", "Agrabad", "territory", "CTG-C", (22.3271, 91.8123)),
]

USERS = [
    ("SO-1001", "Rahim Ahmed", Role.SALES_OFFICER, "T-BAN"),
    ("SO-1042", "Karim Hossain", Role.SALES_OFFICER, "T-MIR"),
    ("SO-1077", "Farhana Akter", Role.SALES_OFFICER, "T-DHN"),
    ("SO-1103", "Tanvir Hasan", Role.SALES_OFFICER, "T-AGR"),
    ("TO-2001", "Nusrat Jahan", Role.SUPERVISOR, "DHK-N"),
    ("BM-3001", "Sadia Rahman", Role.BRAND_MANAGER, "BD"),
    ("MG-4001", "Imran Chowdhury", Role.MANAGEMENT, "BD"),
    ("AD-0001", "Platform Admin", Role.ADMIN, "BD"),
]

# The five shops the field app already shows, kept at the same coordinates.
NAMED_OUTLETS = [
    ("S-101", "Shwapno Banani", "Road 11, Banani", 23.79385, 90.40672, "MT-SS", "T-BAN"),
    ("S-102", "Meena Bazar Banani", "Kemal Ataturk Ave", 23.79610, 90.40190, "MT-SS", "T-BAN"),
    ("S-103", "Agora Superstore", "Block C, Banani", 23.79100, 90.41060, "MT-SS", "T-BAN"),
    ("S-104", "Prince Bazar", "Road 27, Gulshan 1", 23.78820, 90.40430, "GT-GROC", "T-BAN"),
    ("S-105", "Nandan Departmental", "Road 4, Banani", 23.79720, 90.41000, "GT-GROC", "T-BAN"),
]

SHOP_WORDS = ["Bhai Bhai", "Maa", "Rahman", "Bismillah", "Madina", "New", "Haque", "Shapla", "Al-Amin", "Sonar Bangla",
              "Green", "Taj", "Rupali", "Janata", "Mollah"]
SHOP_KIND = {"GT-GROC": "Store", "GT-COS": "Cosmetics", "MT-SS": "Super Shop", "PH": "Pharmacy", "WS": "Traders"}

# Channel mix per territory (weights) and outlets per territory.
CHANNEL_WEIGHTS = {"GT-GROC": 0.55, "GT-COS": 0.15, "MT-SS": 0.08, "PH": 0.14, "WS": 0.08}
OUTLETS_PER_TERRITORY = 34

# Relative demand of each own category by channel (0 = channel does not stock it).
CHANNEL_CATEGORY_AFFINITY = {
    "GT-GROC": {"BAR": 1.0, "HW": 0.4, "OIL": 1.0, "SHAMPOO": 0.3, "LAUNDRY": 1.0},
    "GT-COS": {"BAR": 1.0, "HW": 0.6, "OIL": 0.9, "SHAMPOO": 1.0, "LAUNDRY": 0.1},
    "MT-SS": {"BAR": 2.0, "HW": 1.5, "OIL": 1.6, "SHAMPOO": 1.6, "LAUNDRY": 1.4},
    "PH": {"BAR": 0.6, "HW": 1.4, "OIL": 0.2, "SHAMPOO": 0.4, "LAUNDRY": 0.0},
    "WS": {"BAR": 3.5, "HW": 1.0, "OIL": 3.0, "SHAMPOO": 0.8, "LAUNDRY": 3.5},
}


@dataclass
class SeedSummary:
    organization_id: str
    outlets: int
    products: int
    orders: int
    users: list[str]


class _Writer:
    def __init__(self, session: Session, organization_id: str) -> None:
        self.session = session
        self.organization_id = organization_id

    def add(self, obj):  # type: ignore[no-untyped-def]
        obj.organization_id = self.organization_id
        obj.data_origin = ORIGIN
        self.session.add(obj)
        return obj


def seed(session: Session, anchor: date | None = None, months: int = 6, rng_seed: int = 42) -> SeedSummary:
    anchor = anchor or date.today()
    if session.execute(select(Organization).where(Organization.slug == SLUG)).scalar_one_or_none():
        raise RuntimeError(f"Organization {SLUG!r} already exists; run with --reset to rebuild it.")
    rng = random.Random(rng_seed)
    org = Organization(slug=SLUG, name="ShelfSight Demo — SYNTHETIC DATA", data_origin=ORIGIN)
    session.add(org)
    session.flush()
    w = _Writer(session, org.id)

    manufacturers = {code: w.add(Manufacturer(code=code, name=name, is_own=own)) for code, name, own in MANUFACTURERS}
    session.flush()
    brands = {code: w.add(Brand(code=code, name=name, name_bn=bn, manufacturer_id=manufacturers[m].id))
              for code, name, bn, m in BRANDS}
    categories: dict[str, Category] = {}
    for code, name, parent in CATEGORIES:
        parent_cat = categories.get(parent) if parent else None
        path = (parent_cat.path if parent_cat else "/") + code.lower() + "/"
        categories[code] = w.add(Category(code=code, name=name, parent_id=parent_cat.id if parent_cat else None,
                                          path=path, level=path.count("/") - 2))
        session.flush()
    products: dict[str, Product] = {}
    demand_index: dict[str, float] = {}
    for sku, name, brand, cat, pack, unit, tier, mrp, demand in PRODUCTS:
        product = w.add(Product(sku=sku, name=name, brand_id=brands[brand].id,
                                manufacturer_id=brands[brand].manufacturer_id, category_id=categories[cat].id,
                                pack_size=pack, pack_unit=unit, price_tier=tier,
                                attributes={"synthetic": True}, launched_on=anchor - timedelta(days=900)))
        products[sku] = product
        if demand is not None:
            demand_index[sku] = demand
    session.flush()
    for sku, *_rest in PRODUCTS:
        mrp = _rest[6]
        w.add(ProductPrice(product_id=products[sku].id, price_type="mrp", amount=mrp,
                           effective_from=anchor - timedelta(days=900)))
        w.add(ProductPrice(product_id=products[sku].id, price_type="trade", amount=round(mrp * 0.88, 2),
                           effective_from=anchor - timedelta(days=900)))

    channels: dict[str, Channel] = {}
    for code, name, parent, bn in CHANNELS:
        parent_ch = channels.get(parent) if parent else None
        path = (parent_ch.path if parent_ch else "/") + code.lower() + "/"
        channels[code] = w.add(Channel(code=code, name=name, name_bn=bn, parent_id=parent_ch.id if parent_ch else None,
                                       path=path))
        session.flush()

    territories: dict[str, Territory] = {}
    centers: dict[str, tuple[float, float]] = {}
    for code, name, kind, parent, center in TERRITORIES:
        parent_t = territories.get(parent) if parent else None
        path = (parent_t.path if parent_t else "/") + code.lower() + "/"
        territories[code] = w.add(Territory(code=code, name=name, kind=kind, parent_id=parent_t.id if parent_t else None,
                                            path=path))
        session.flush()
        if center:
            centers[code] = center
    distributors = {code: w.add(Distributor(code=f"D-{code}", name=f"{territories[code].name} Distribution (synthetic)",
                                            territory_id=territories[code].id)) for code in centers}

    users: dict[str, User] = {}
    for employee_id, name, role, territory in USERS:
        users[employee_id] = w.add(User(employee_id=employee_id, name=name, role=role,
                                        password_hash=hash_password(DEMO_PASSWORD),
                                        territory_id=territories[territory].id))
    session.flush()
    for so in ("SO-1001", "SO-1042"):
        users[so].supervisor_id = users["TO-2001"].id

    # --- outlets ----------------------------------------------------------------------------
    outlets: list[tuple[Outlet, str]] = []
    for code, name, address, lat, lng, channel, territory in NAMED_OUTLETS:
        outlet = w.add(Outlet(code=code, name=name, address=address, lat=lat, lng=lng,
                              territory_id=territories[territory].id, distributor_id=distributors[territory].id,
                              channel_id=channels[channel].id,
                              shelf_meters=24.0 if channel == "MT-SS" else 3.5,
                              size_sqft=4000 if channel == "MT-SS" else 350))
        outlets.append((outlet, channel))
    counter = 200
    for territory, (clat, clng) in centers.items():
        count = OUTLETS_PER_TERRITORY - (5 if territory == "T-BAN" else 0)
        for _ in range(count):
            counter += 1
            channel = rng.choices(list(CHANNEL_WEIGHTS), weights=list(CHANNEL_WEIGHTS.values()))[0]
            size = {"GT-GROC": rng.uniform(120, 600), "GT-COS": rng.uniform(150, 500), "MT-SS": rng.uniform(2500, 9000),
                    "PH": rng.uniform(100, 400), "WS": rng.uniform(600, 2500)}[channel]
            outlet = w.add(Outlet(
                code=f"S-{counter}", name=f"{rng.choice(SHOP_WORDS)} {SHOP_KIND[channel]}",
                owner_name=f"Owner {counter} (synthetic)", address=f"Synthetic address {counter}",
                lat=round(clat + rng.uniform(-0.012, 0.012), 6), lng=round(clng + rng.uniform(-0.012, 0.012), 6),
                territory_id=territories[territory].id, distributor_id=distributors[territory].id,
                channel_id=channels[channel].id, size_sqft=round(size), shelf_meters=round(size / 110, 1),
            ))
            outlets.append((outlet, channel))
    session.flush()

    officer_for = {"T-BAN": "SO-1001", "T-MIR": "SO-1042", "T-DHN": "SO-1077", "T-AGR": "SO-1103"}
    territory_code = {t.id: code for code, t in territories.items()}
    for outlet, _ in outlets:
        w.add(OutletAssignment(outlet_id=outlet.id, user_id=users[officer_for[territory_code[outlet.territory_id]]].id,
                               effective_from=anchor - timedelta(days=365)))

    # --- order history ----------------------------------------------------------------------
    own_skus = [p for p in PRODUCTS if p[8] is not None]
    order_count = 0
    start = anchor - timedelta(days=int(months * 30.44))
    for outlet, channel in outlets:
        affinity = CHANNEL_CATEGORY_AFFINITY[channel]
        scale = math.sqrt((outlet.size_sqft or 300) / 300)
        # Each outlet carries a subset of SKUs: some gaps are deliberate so peers reveal them.
        carried = []
        for sku, *_r in own_skus:
            category = _r[2]
            if affinity.get(category, 0) == 0:
                continue
            if rng.random() < 0.82:
                carried.append(sku)
        visit_every = rng.choice([7, 7, 14]) if channel != "WS" else 7
        day = start + timedelta(days=rng.randint(0, visit_every - 1))
        number = 0
        while day <= anchor:
            number += 1
            items = []
            for sku in carried:
                spec = next(p for p in own_skus if p[0] == sku)
                weekly = spec[8] * affinity[spec[3]] * scale * 6
                mean = weekly * visit_every / 7
                quantity = max(0, int(rng.gauss(mean, mean * 0.35) + 0.5))
                if quantity and rng.random() < 0.93:
                    items.append((sku, quantity, round(spec[7] * 0.88, 2)))
            if items:
                order = w.add(Order(outlet_id=outlet.id, distributor_id=outlet.distributor_id, order_date=day,
                                    source="ingest", external_ref=f"SYN-{outlet.code}-{number:04d}", status="confirmed",
                                    user_id=users[officer_for[territory_code[outlet.territory_id]]].id))
                for sku, quantity, price in items:
                    order.items.append(OrderItem(organization_id=org.id, data_origin=ORIGIN, product_id=products[sku].id,
                                                 quantity=quantity, unit_price=price, line_value=round(quantity * price, 2)))
                order_count += 1
            day += timedelta(days=visit_every)
    session.flush()

    # --- promotions ----------------------------------------------------------------------------
    promo = w.add(Promotion(code="PROMO-MERIL-3P1", name="Meril Buy 3 Get 1 (synthetic)",
                            mechanic="Buy 3 Meril 100g soaps, get 1 free", starts_on=anchor - timedelta(days=10),
                            ends_on=anchor + timedelta(days=20), channel_id=channels["GT"].id))
    session.flush()
    w.add(PromotionProduct(promotion_id=promo.id, product_id=products["SQ-MER-SOAP-100"].id, discount_pct=25))
    promo2 = w.add(Promotion(code="PROMO-SEPNIL-RF", name="Sepnil Refill Trade Offer (synthetic)",
                             mechanic="5% extra trade margin on Sepnil refills", starts_on=anchor - timedelta(days=5),
                             ends_on=anchor + timedelta(days=25)))
    session.flush()
    w.add(PromotionProduct(promotion_id=promo2.id, product_id=products["SQ-SEP-HW-RF-170"].id, discount_pct=5))

    # --- rules (versioned configuration) ---------------------------------------------------
    portfolio_rules = w.add(RuleSet(kind="portfolio", name="Own portfolio mix targets (synthetic)", version=1,
                                    status="active", effective_from=anchor - timedelta(days=30)))
    assortment_rules = w.add(RuleSet(kind="assortment", name="Core assortment by channel (synthetic)", version=1,
                                     status="active", effective_from=anchor - timedelta(days=30)))
    placement_rules = w.add(RuleSet(kind="placement", name="Channel placement guidelines (synthetic)", version=1,
                                    status="active", effective_from=anchor - timedelta(days=30)))
    session.flush()
    for channel, shares in {
        "GT-GROC": {"MERIL": 0.36, "JUI": 0.22, "CHAKA": 0.27, "SEPNIL": 0.15},
        "MT-SS": {"MERIL": 0.34, "JUI": 0.18, "CHAKA": 0.18, "SEPNIL": 0.30},
        "PH": {"SEPNIL": 0.65, "MERIL": 0.30},
    }.items():
        for brand, share in shares.items():
            w.add(PortfolioTarget(rule_set_id=portfolio_rules.id, channel_id=channels[channel].id, dimension="brand",
                                  dimension_value=brands[brand].id, target_share=share, tolerance=0.07))
    core = {
        "GT-GROC": ["SQ-MER-SOAP-100", "SQ-JUI-OIL-100", "SQ-CHK-DET-500"],
        "GT-COS": ["SQ-MER-SOAP-100", "SQ-MER-SHMP-180", "SQ-JUI-OIL-100"],
        "MT-SS": ["SQ-MER-SOAP-100", "SQ-MER-SOAP-150", "SQ-SEP-HW-200", "SQ-JUI-OIL-200", "SQ-CHK-DET-1K"],
        "PH": ["SQ-SEP-HW-200", "SQ-SEP-HW-RF-170"],
        "WS": ["SQ-MER-SOAP-100", "SQ-JUI-OIL-200", "SQ-CHK-DET-1K"],
    }
    for channel, skus in core.items():
        for index, sku in enumerate(skus):
            w.add(CoreAssortmentItem(rule_set_id=assortment_rules.id, channel_id=channels[channel].id,
                                     product_id=products[sku].id, min_facings=2, priority=1 if index == 0 else 2))
    w.add(PlacementRule(rule_set_id=placement_rules.id, channel_id=channels["GT"].id, category_id=categories["SKIN"].id,
                        manufacturer_id=manufacturers["SQ"].id, preferred_band="eye", min_facings=4,
                        min_share_of_shelf=0.30, priority=1,
                        description="Square skin-cleansing range at eye level, ≥4 facings, ≥30% of shelf"))
    w.add(PlacementRule(rule_set_id=placement_rules.id, channel_id=channels["MT"].id, category_id=categories["SKIN"].id,
                        manufacturer_id=manufacturers["SQ"].id, preferred_band="eye", min_facings=8,
                        min_share_of_shelf=0.35, priority=1,
                        description="Square skin-cleansing block at eye level, ≥8 facings, ≥35% of shelf"))
    w.add(PlacementRule(rule_set_id=placement_rules.id, channel_id=channels["MT"].id, category_id=categories["BAR"].id,
                        product_id=products["SQ-MER-SOAP-100"].id, preferred_band="eye", min_facings=3, priority=2,
                        description="Meril 100g at eye level with ≥3 facings"))
    w.add(PlacementRule(rule_set_id=placement_rules.id, channel_id=channels["PH"].id, category_id=categories["HW"].id,
                        brand_id=brands["SEPNIL"].id, preferred_band="eye", min_facings=2, priority=1,
                        description="Sepnil hand wash at eye level in pharmacies"))

    # --- outlet classification scheme ------------------------------------------------------
    scheme = w.add(ClassScheme(code="POTENTIAL", name="Outlet Potential (synthetic v1)", version=1, status="active",
                               description="Rule-based potential classes; thresholds are placeholders to be set by Square."))
    session.flush()
    for rank, code, label, criteria in [
        (1, "A", "High potential", [{"feature": "sales_percentile_in_channel", "op": ">=", "value": 0.8},
                                    {"feature": "distinct_skus", "op": ">=", "value": 6}]),
        (2, "B", "Core", [{"feature": "sales_percentile_in_channel", "op": ">=", "value": 0.45},
                          {"feature": "distinct_categories", "op": ">=", "value": 3}]),
        (3, "C", "Developing", [{"feature": "sales_percentile_in_channel", "op": ">=", "value": 0.15}]),
        (4, "D", "Low activity", []),
    ]:
        w.add(OutletClass(scheme_id=scheme.id, code=code, label=label, rank=rank, criteria=criteria))

    # --- manual competitor observations with prices (a few outlets) -----------------------
    for outlet, channel in outlets[:12]:
        for sku in ("UNI-LUX-100", "UNI-LFB-100", "RB-DET-SOAP-75", "MAR-PAR-OIL-200"):
            product = products[sku]
            spec = next(p for p in PRODUCTS if p[0] == sku)
            w.add(CompetitorObservation(outlet_id=outlet.id, manufacturer_id=product.manufacturer_id,
                                        brand_id=product.brand_id, product_id=product.id, kind="price",
                                        observed_price=round(spec[7] * rng.uniform(0.9, 1.02), 0),
                                        source="manual", notes="Synthetic observation"))
    session.flush()
    return SeedSummary(organization_id=org.id, outlets=len(outlets), products=len(products), orders=order_count,
                       users=[u[0] for u in USERS])


def reset(session: Session) -> None:
    """Delete the synthetic organization and everything in it (never touches other orgs)."""
    from ..models import Base

    org = session.execute(select(Organization).where(Organization.slug == SLUG)).scalar_one_or_none()
    if org is None:
        return
    for table in reversed(Base.metadata.sorted_tables):
        if table.name == "organization":
            continue
        if "organization_id" in table.c:
            session.execute(table.delete().where(table.c.organization_id == org.id))
    session.delete(org)
    session.flush()

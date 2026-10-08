from __future__ import annotations

import os
from datetime import date

import cv2
import numpy as np
import pytest

os.environ.setdefault("SHELFSIGHT_JSON_LOGS", "0")

from fastapi.testclient import TestClient  # noqa: E402
from sqlalchemy import select  # noqa: E402

from retail_platform import config, db  # noqa: E402
from retail_platform.models import Base, Manufacturer, Product  # noqa: E402
from retail_platform.seed import synthetic  # noqa: E402
from retail_platform.services import intelligence  # noqa: E402
from retail_platform.vision import registry  # noqa: E402
from retail_platform.vision.base import ProviderDetection  # noqa: E402
from retail_platform.vision.fake import ScriptedProvider  # noqa: E402


@pytest.fixture(scope="session")
def platform(tmp_path_factory):
    root = tmp_path_factory.mktemp("platform")
    settings = config.Settings(
        database_url=f"sqlite:///{(root / 'test.db').as_posix()}", blob_directory=root / "blobs",
        jwt_secret="test-secret-" + "x" * 32, run_worker=False, review_confidence_threshold=0.75,
    )
    config.override_settings(settings)
    engine = db.configure(settings.database_url)
    Base.metadata.create_all(engine)
    with db.session_factory()() as session:
        summary = synthetic.seed(session, anchor=date.today())
        session.commit()
        intelligence.classify_outlets(session, summary.organization_id, "synthetic")
        session.commit()
    from retail_platform.main import create_app

    app = create_app(run_worker=False, auto_migrate=False, mount_legacy=False)
    with TestClient(app) as client:
        yield {"client": client, "org_id": summary.organization_id}


@pytest.fixture(scope="session")
def ids(platform):
    with db.session_factory()() as session:
        products = {p.sku: p.id for p in session.execute(select(Product)).scalars()}
        manufacturers = {m.code: m.id for m in session.execute(select(Manufacturer)).scalars()}
    return {"products": products, "manufacturers": manufacturers}


def login(client, employee_id: str, password: str = synthetic.DEMO_PASSWORD) -> dict:
    response = client.post("/v2/auth/login", json={"employee_id": employee_id, "password": password})
    assert response.status_code == 200, response.text
    return {"Authorization": f"Bearer {response.json()['access_token']}"}


@pytest.fixture(scope="session")
def officer(platform):
    return login(platform["client"], "SO-1001")


@pytest.fixture(scope="session")
def supervisor(platform):
    return login(platform["client"], "TO-2001")


@pytest.fixture(scope="session")
def admin(platform):
    return login(platform["client"], "AD-0001")


@pytest.fixture
def scripted_provider(ids):
    """Three shelf rows: competitor on top, own at eye level, two unidentified facings at the bottom."""
    sq = ids["manufacturers"]["SQ"]
    uni = ids["manufacturers"]["UNI"]
    meril = ids["products"]["SQ-MER-SOAP-100"]
    lux = ids["products"]["UNI-LUX-100"]
    detections = []
    for i in range(4):
        detections.append(ProviderDetection(0.05 + i * 0.2, 0.05, 0.15, 0.22, "competitor", 0.92, lux, uni))
    for i in range(3):
        detections.append(ProviderDetection(0.05 + i * 0.2, 0.38, 0.15, 0.22, "own", 0.95, meril if i == 0 else None, sq))
    for i in range(2):
        detections.append(ProviderDetection(0.05 + i * 0.2, 0.72, 0.15, 0.22, "unknown", 0.40))
    provider = ScriptedProvider(detections)
    registry.set_provider(provider)
    yield provider
    registry.set_provider(None)


def shelf_jpeg(seed: int = 0) -> bytes:
    rng = np.random.default_rng(seed)
    image = rng.integers(40, 220, size=(900, 1200, 3), dtype=np.uint8)
    ok, data = cv2.imencode(".jpg", image)
    assert ok
    return data.tobytes()

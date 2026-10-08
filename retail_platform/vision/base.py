"""Vision provider contract.

A provider turns one image into facings with an optional identity. It knows nothing
about outlets, rules or the database. Orchestration (vision.pipeline) records the
inference, assigns shelf rows, flags low confidence for review and persists results.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Protocol


@dataclass(frozen=True, slots=True)
class CatalogEntry:
    """What a recognising provider may answer with. Closed set: nothing outside it is valid."""

    product_id: str
    sku: str
    name: str
    brand: str
    manufacturer_id: str
    manufacturer: str
    is_own: bool
    category: str
    pack: str | None


@dataclass(slots=True)
class ProviderDetection:
    # Normalised box, origin top-left.
    x: float
    y: float
    width: float
    height: float
    label: str  # own | competitor | unknown
    confidence: float
    product_id: str | None = None
    manufacturer_id: str | None = None
    evidence: dict = field(default_factory=dict)


@dataclass(slots=True)
class ProviderResult:
    detections: list[ProviderDetection]
    warnings: list[str] = field(default_factory=list)
    annotated_jpeg: bytes | None = None
    cost_usd: float | None = None
    raw: dict = field(default_factory=dict)


class VisionProvider(Protocol):
    provider: str
    model_code: str
    version: str
    config: dict

    def analyze(self, image: bytes, catalog: list[CatalogEntry], own_manufacturer_id: str | None) -> ProviderResult: ...

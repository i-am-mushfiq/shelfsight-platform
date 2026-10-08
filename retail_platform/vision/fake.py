"""Deterministic provider for tests and offline demos. Never used for real inferences."""

from __future__ import annotations

from .base import CatalogEntry, ProviderDetection, ProviderResult


class ScriptedProvider:
    provider = "scripted"
    model_code = "scripted-test-provider"
    version = "1"
    config: dict = {}

    def __init__(self, detections: list[ProviderDetection] | None = None) -> None:
        self.detections = detections or []
        self.calls = 0

    def analyze(self, image: bytes, catalog: list[CatalogEntry], own_manufacturer_id: str | None) -> ProviderResult:
        self.calls += 1
        return ProviderResult(detections=list(self.detections))

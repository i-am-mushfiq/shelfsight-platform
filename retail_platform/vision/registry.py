"""Resolves the configured vision provider and its registered model version."""

from __future__ import annotations

import threading

from sqlalchemy import select
from sqlalchemy.orm import Session

from ..config import Settings
from ..models import Model, ModelVersion, utcnow
from .base import VisionProvider

_lock = threading.Lock()
_provider: VisionProvider | None = None


def build_provider(settings: Settings) -> VisionProvider:
    from .opencv_baseline import OpenCvBaselineProvider

    baseline = OpenCvBaselineProvider()
    if settings.vision_provider == "opencv-baseline":
        return baseline
    if settings.vision_provider == "claude-crop":
        from .llm_recognizer import ClaudeCropRecognizer, RecognizerConfig

        return ClaudeCropRecognizer(baseline, config=RecognizerConfig(model=settings.recognizer_model))
    raise ValueError(f"Unknown vision provider {settings.vision_provider!r}")


def get_provider(settings: Settings) -> VisionProvider:
    global _provider
    with _lock:
        if _provider is None:
            _provider = build_provider(settings)
        return _provider


def set_provider(provider: VisionProvider | None) -> None:
    """Install a provider explicitly (tests, evaluation runs)."""
    global _provider
    with _lock:
        _provider = provider


def ensure_model_version(session: Session, organization_id: str, provider: VisionProvider) -> ModelVersion:
    """Register (once) the model + version the provider reports. Every inference points at one."""
    model = session.execute(
        select(Model).where(Model.organization_id == organization_id, Model.code == provider.model_code)
    ).scalar_one_or_none()
    if model is None:
        model = Model(organization_id=organization_id, code=provider.model_code, task="shelf_recognition",
                      description=f"Provider {provider.provider}")
        session.add(model)
        session.flush()
    version = session.execute(
        select(ModelVersion).where(ModelVersion.model_id == model.id, ModelVersion.version == provider.version)
    ).scalar_one_or_none()
    if version is None:
        version = ModelVersion(organization_id=organization_id, model_id=model.id, version=provider.version,
                               provider=provider.provider, config=provider.config, status="active",
                               activated_at=utcnow())
        session.add(version)
        session.flush()
    return version

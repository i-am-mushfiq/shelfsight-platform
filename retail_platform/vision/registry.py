"""Resolves the configured vision provider and its registered model version."""

from __future__ import annotations

import os
import threading

from sqlalchemy import select
from sqlalchemy.orm import Session

from ..config import Settings
from ..models import Model, ModelVersion, utcnow
from .base import VisionProvider

_lock = threading.Lock()
_provider: VisionProvider | None = None


PROVIDERS = ("auto", "visual-lookup", "packshot-match", "claude-shelf", "claude-crop", "opencv-baseline")


def anthropic_configured() -> bool:
    """Credentials for the Anthropic API are present and the SDK is installed."""
    if not (os.getenv("ANTHROPIC_API_KEY") or os.getenv("ANTHROPIC_AUTH_TOKEN")):
        return False
    try:
        import anthropic  # noqa: F401
    except ImportError:
        return False
    return True


def resolve_provider_name(settings: Settings) -> str:
    if settings.vision_provider not in PROVIDERS:
        raise ValueError(f"Unknown vision provider {settings.vision_provider!r}; use one of {PROVIDERS}")
    if settings.vision_provider != "auto":
        return settings.vision_provider
    # Both lookups need no external service: the visual one (detector + CLIP, tolerant of redrawn
    # artwork) when PyTorch is installed, otherwise exact pack-shot matching. An LLM provider is
    # only ever used when configured by name.
    from .visual_lookup import available

    return "visual-lookup" if available() else "packshot-match"


def build_provider(settings: Settings) -> VisionProvider:
    from .opencv_baseline import OpenCvBaselineProvider

    name = resolve_provider_name(settings)
    baseline = OpenCvBaselineProvider()
    if name == "opencv-baseline":
        return baseline
    if name == "packshot-match":
        from .packshot_matcher import PackshotMatchProvider

        return PackshotMatchProvider(baseline)
    if name == "visual-lookup":
        from .packshot_matcher import PackshotMatchProvider
        from .visual_lookup import VisualConfig, VisualLookupProvider

        return VisualLookupProvider(PackshotMatchProvider(None), VisualConfig(screen_photos=settings.screen_photos))
    if name == "claude-crop":
        from .llm_recognizer import ClaudeCropRecognizer, RecognizerConfig

        return ClaudeCropRecognizer(baseline, config=RecognizerConfig(model=settings.recognizer_model))
    from .claude_shelf import ClaudeShelfRecognizer, ShelfRecognizerConfig

    return ClaudeShelfRecognizer(baseline, config=ShelfRecognizerConfig(
        model=settings.recognizer_model, effort=settings.recognizer_effort,
        max_image_side=settings.recognizer_image_side,
    ))


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


_live: object | None = None


def get_live_matcher():  # type: ignore[no-untyped-def]
    """Lookup for live camera frames: the visual lookup when it is the configured recogniser,
    otherwise the pack-shot matcher without a fallback detector, so it stays fast."""
    global _live
    from ..config import get_settings
    from .packshot_matcher import PackshotMatchProvider

    with _lock:
        if _live is None:
            if resolve_provider_name(get_settings()) == "visual-lookup":
                from .visual_lookup import VisualConfig, VisualLookupProvider

                _live = VisualLookupProvider(PackshotMatchProvider(None),
                                             VisualConfig(screen_photos=get_settings().screen_photos))
            else:
                _live = PackshotMatchProvider(None)
        return _live

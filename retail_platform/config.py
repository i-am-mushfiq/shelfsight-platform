from __future__ import annotations

import logging
import os
import secrets
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

log = logging.getLogger(__name__)


def _bool(name: str, default: bool) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _database_url(url: str) -> str:
    """Hosting providers hand out postgres:// URLs; SQLAlchemy needs the driver named (psycopg 3)."""
    for prefix in ("postgres://", "postgresql://"):
        if url.startswith(prefix):
            return "postgresql+psycopg://" + url[len(prefix):]
    return url


def _jwt_secret(environment: str) -> str:
    secret = os.getenv("SHELFSIGHT_JWT_SECRET")
    if secret:
        return secret
    if environment == "production":
        raise RuntimeError("SHELFSIGHT_JWT_SECRET must be set in production.")
    log.warning("SHELFSIGHT_JWT_SECRET not set; using an ephemeral development secret.")
    return secrets.token_urlsafe(48)


@dataclass(frozen=True, slots=True)
class Settings:
    environment: str = field(default_factory=lambda: os.getenv("SHELFSIGHT_ENV", "development"))
    database_url: str = field(
        default_factory=lambda: _database_url(
            os.getenv("SHELFSIGHT_DATABASE_URL", f"sqlite:///{(ROOT / 'var' / 'shelfsight.db').as_posix()}")
        )
    )
    blob_directory: Path = field(
        default_factory=lambda: Path(os.getenv("SHELFSIGHT_BLOB_DIR", ROOT / "var" / "blobs"))
    )
    jwt_secret: str = ""
    access_token_minutes: int = field(
        default_factory=lambda: int(os.getenv("SHELFSIGHT_ACCESS_TOKEN_MINUTES", "720"))
    )
    # Vision provider used for new inferences: "auto" (claude-shelf when Anthropic credentials
    # are set, otherwise opencv-baseline), "claude-shelf", "claude-crop" or "opencv-baseline".
    vision_provider: str = field(
        default_factory=lambda: os.getenv("SHELFSIGHT_VISION_PROVIDER", "auto")
    )
    recognizer_model: str = field(
        default_factory=lambda: os.getenv("SHELFSIGHT_RECOGNIZER_MODEL", "claude-opus-5-5")
    )
    recognizer_effort: str = field(
        default_factory=lambda: os.getenv("SHELFSIGHT_RECOGNIZER_EFFORT", "medium")
    )
    # Longest side, in pixels, of the shelf photo sent to the recogniser.
    recognizer_image_side: int = field(
        default_factory=lambda: int(os.getenv("SHELFSIGHT_RECOGNIZER_IMAGE_SIDE", "1600"))
    )
    # Catalogue pack shots sent with each recognition request (0 disables them).
    max_reference_images: int = field(
        default_factory=lambda: int(os.getenv("SHELFSIGHT_MAX_REFERENCE_IMAGES", "24"))
    )
    # What submitting a visit does with the shelf-driven order: "confirm" places it,
    # "draft" leaves it for the officer to confirm, "off" creates none.
    auto_order: str = field(default_factory=lambda: os.getenv("SHELFSIGHT_AUTO_ORDER", "confirm"))
    # Photos taken of a screen (demo shelves shown on a monitor): auto-detect, always or never.
    screen_photos: str = field(default_factory=lambda: os.getenv("SHELFSIGHT_SCREEN_PHOTOS", "auto"))
    # Detections below this confidence are flagged for human verification.
    review_confidence_threshold: float = field(
        default_factory=lambda: float(os.getenv("SHELFSIGHT_REVIEW_THRESHOLD", "0.75"))
    )
    run_worker: bool = field(default_factory=lambda: _bool("SHELFSIGHT_RUN_WORKER", True))
    max_upload_bytes: int = field(
        default_factory=lambda: int(os.getenv("SHELFSIGHT_MAX_UPLOAD_BYTES", str(12 * 1024 * 1024)))
    )

    def __post_init__(self) -> None:
        if self.screen_photos not in {"auto", "always", "never"}:
            raise ValueError("SHELFSIGHT_SCREEN_PHOTOS must be auto, always or never")
        if self.auto_order not in {"confirm", "draft", "off"}:
            raise ValueError("SHELFSIGHT_AUTO_ORDER must be confirm, draft or off")
        if not self.jwt_secret:
            object.__setattr__(self, "jwt_secret", _jwt_secret(self.environment))


_settings: Settings | None = None


def get_settings() -> Settings:
    global _settings
    if _settings is None:
        _settings = Settings()
    return _settings


def override_settings(settings: Settings) -> None:
    """Used by tests and CLI tools to install explicit settings."""
    global _settings
    _settings = settings

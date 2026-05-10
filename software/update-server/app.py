import hashlib
import os
from pathlib import Path

from fastapi import FastAPI, HTTPException, Response
from pydantic import BaseModel, Field


class LatestFirmwareResponse(BaseModel):
    version: str
    mac: str = Field(
        description="Hex-encoded MD5(secret || firmware) value for the firmware binary."
    )
    url: str = Field(description="Relative download URL for the latest firmware binary.")


def _get_firmware_version() -> str:
    return os.environ.get("FIRMWARE_VERSION", "1.2.1")


def _get_firmware_path() -> Path:
    return Path(
        os.environ.get(
            "FIRMWARE_PATH", "/opt/cybics/update-server/firmware/current.bin"
        )
    )


def _get_secret_path() -> Path:
    return Path(os.environ.get("SECRET_PATH", "/opt/cybics/secrets/secret.bin"))


def _read_secret_key() -> bytes:
    secret_path = _get_secret_path()
    if not secret_path.is_file():
        raise HTTPException(status_code=500, detail="MAC secret is not available")
    return secret_path.read_bytes()


def _read_firmware_bytes() -> bytes:
    firmware_path = _get_firmware_path()
    if not firmware_path.is_file():
        raise HTTPException(status_code=500, detail="Firmware file is not available")
    return firmware_path.read_bytes()


def _compute_firmware_mac(firmware: bytes, secret: bytes) -> str:
    return hashlib.md5(secret + firmware).hexdigest()


def create_app() -> FastAPI:
    app = FastAPI(
        title="CybICS Firmware Update Server",
        version="1.0.0",
        description=(
            "Minimal firmware update server for the CybICS CTF scenario. "
            "Firmware authenticity is represented as a hex-encoded "
            "MD5(secret || firmware) MAC."
        ),
    )

    @app.get(
        "/api/v1/firmware/latest",
        response_model=LatestFirmwareResponse,
        tags=["firmware"],
    )
    def get_latest_firmware() -> LatestFirmwareResponse:
        version = _get_firmware_version()
        firmware = _read_firmware_bytes()
        mac = _compute_firmware_mac(firmware, _read_secret_key())
        return LatestFirmwareResponse(
            version=version,
            mac=mac,
            url=f"/api/v1/firmware/download/{version}",
        )

    @app.get(
        "/api/v1/firmware/download/{version}",
        response_class=Response,
        tags=["firmware"],
        responses={
            200: {
                "description": "Firmware binary",
                "content": {
                    "application/octet-stream": {
                        "schema": {"type": "string", "format": "binary"}
                    }
                },
                "headers": {
                    "X-Firmware-MAC": {
                        "description": (
                            "Hex-encoded MD5(secret || firmware) value for the "
                            "returned firmware binary."
                        ),
                        "schema": {"type": "string"},
                    }
                },
            },
            404: {"description": "Firmware version not found"},
            500: {"description": "Firmware file or MAC is not configured"},
        },
    )
    def download_firmware(version: str) -> Response:
        expected_version = _get_firmware_version()
        if version != expected_version:
            raise HTTPException(status_code=404, detail="Firmware version not found")

        firmware = _read_firmware_bytes()
        mac = _compute_firmware_mac(firmware, _read_secret_key())

        return Response(
            content=firmware,
            media_type="application/octet-stream",
            headers={"X-Firmware-MAC": mac},
        )

    return app


app = create_app()

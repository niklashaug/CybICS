import hashlib
import importlib.util
from pathlib import Path

from fastapi.testclient import TestClient


MODULE_PATH = (
    Path(__file__).resolve().parent.parent / "software" / "update-server" / "app.py"
)


def _load_update_server_module():
    spec = importlib.util.spec_from_file_location("update_server_app", MODULE_PATH)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class TestUpdateServerMac:
    def test_latest_returns_dynamic_mac(self, monkeypatch, tmp_path):
        secret = b"0123456789abcdef"
        firmware = b"\xAA\xBB\xCC\xDD" * 32
        secret_path = tmp_path / "secret.bin"
        firmware_path = tmp_path / "firmware.bin"
        secret_path.write_bytes(secret)
        firmware_path.write_bytes(firmware)

        monkeypatch.setenv("SECRET_PATH", str(secret_path))
        monkeypatch.setenv("FIRMWARE_PATH", str(firmware_path))
        monkeypatch.setenv("FIRMWARE_VERSION", "9.9.9")

        module = _load_update_server_module()
        client = TestClient(module.create_app())

        response = client.get("/api/v1/firmware/latest")
        assert response.status_code == 200
        body = response.json()
        assert body["version"] == "9.9.9"
        assert body["url"] == "/api/v1/firmware/download/9.9.9"
        assert body["mac"] == hashlib.md5(secret + firmware).hexdigest()

    def test_download_returns_matching_header_mac(self, monkeypatch, tmp_path):
        secret = b"fedcba9876543210"
        firmware = b"\x01\x02\x03\x04" * 64
        secret_path = tmp_path / "secret.bin"
        firmware_path = tmp_path / "firmware.bin"
        secret_path.write_bytes(secret)
        firmware_path.write_bytes(firmware)

        monkeypatch.setenv("SECRET_PATH", str(secret_path))
        monkeypatch.setenv("FIRMWARE_PATH", str(firmware_path))
        monkeypatch.setenv("FIRMWARE_VERSION", "1.2.3")

        module = _load_update_server_module()
        client = TestClient(module.create_app())

        response = client.get("/api/v1/firmware/download/1.2.3")
        assert response.status_code == 200
        assert response.content == firmware
        assert response.headers["x-firmware-mac"] == hashlib.md5(
            secret + firmware
        ).hexdigest()

    def test_latest_fails_when_secret_missing(self, monkeypatch, tmp_path):
        firmware_path = tmp_path / "firmware.bin"
        firmware_path.write_bytes(b"firmware")

        monkeypatch.setenv("SECRET_PATH", str(tmp_path / "missing.secret"))
        monkeypatch.setenv("FIRMWARE_PATH", str(firmware_path))

        module = _load_update_server_module()
        client = TestClient(module.create_app())

        response = client.get("/api/v1/firmware/latest")
        assert response.status_code == 500
        assert response.json()["detail"] == "MAC secret is not available"

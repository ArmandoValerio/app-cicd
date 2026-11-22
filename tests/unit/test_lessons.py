"""Pruebas unitarias para la API de micro-lecciones y audio nativo de app-cicd."""

import importlib
import sys
from pathlib import Path

from fastapi.testclient import TestClient

ROOT_DIR = Path(__file__).resolve().parents[2]
if str(ROOT_DIR) not in sys.path:
    sys.path.insert(0, str(ROOT_DIR))

main_module = importlib.import_module("src.main")

client = TestClient(main_module.app)


def test_healthz_endpoint() -> None:
    """Verifica que /healthz responda HTTP 200 con estado ok."""
    response = client.get("/healthz")
    assert response.status_code == 200
    assert "application/json" in response.headers["content-type"]
    assert "charset=utf-8" in response.headers["content-type"].lower()
    assert response.json() == {"status": "ok", "service": "app"}


def test_ready_endpoint_ok() -> None:
    """Verifica que /ready responda HTTP 200 cuando el servicio está listo."""
    response = client.get("/ready")
    assert response.status_code == 200
    payload = response.json()
    assert payload["status"] == "ready"
    assert payload["service"] == "app"
    assert payload["checks"] == {
        "lessons_catalog": "ok",
        "speech_samples": "ok",
    }


def test_ready_endpoint_not_ready(monkeypatch) -> None:
    """Verifica que /ready devuelva HTTP 503 cuando la aplicación no está lista."""
    monkeypatch.setattr(main_module, "_APP_READY", False)
    response = client.get("/ready")
    assert response.status_code == 503
    assert response.json() == {"status": "not_ready", "service": "app"}


def test_nahuatl_lesson_utf8_and_contract() -> None:
    """Verifica contrato JSON y preservación UTF-8 de saltillo y macrones en Náhuatl."""
    response = client.get("/api/v1/lessons/nahuatl/unidad-1")
    assert response.status_code == 200
    content_type = response.headers["content-type"].lower()
    assert "application/json" in content_type
    assert "charset=utf-8" in content_type

    raw_text = response.content.decode("utf-8")
    assert "\\u" not in raw_text
    assert "ꞌ" in raw_text
    assert "ō" in raw_text
    assert "ā" in raw_text
    assert "ē" in raw_text

    payload = response.json()
    assert payload["lesson_id"] == "nahuatl-unidad-1"
    assert payload["language"] == "Náhuatl"
    assert payload["encoding"] == "UTF-8"
    assert set(payload["supported_languages"]) == {
        "Náhuatl",
        "Maya Yucateco",
        "Zapoteco",
        "Mixteco",
        "Tsotsil",
    }
    assert len(payload["items"]) >= 4
    assert len(payload["exercises"]) >= 3

    terms = [item["term"] for item in payload["items"]]
    assert "Cualli tōnalli" in terms
    assert "Niltze, ¿quēn timoyetzticaꞌ?" in terms


def test_speech_sample_get_and_head() -> None:
    """Verifica descarga GET y verificación HEAD de muestras WAV nativas."""
    get_resp = client.get("/api/v1/speech/sample/cualli-tonalli.wav")
    assert get_resp.status_code == 200
    assert get_resp.headers["content-type"] == "audio/wav"
    assert get_resp.headers["x-audio-language"] == "nahuatl"
    assert get_resp.content.startswith(b"RIFF")
    assert b"WAVE" in get_resp.content[:16]
    assert len(get_resp.content) >= 44

    head_resp = client.head("/api/v1/speech/sample/cualli-tonalli.wav")
    assert head_resp.status_code == 200
    assert head_resp.headers["content-type"] == "audio/wav"


def test_speech_sample_not_found() -> None:
    """Verifica HTTP 404 cuando la muestra solicitada no existe."""
    response = client.get("/api/v1/speech/sample/no-existe.wav")
    assert response.status_code == 404
    assert response.json()["detail"] == "Muestra de audio no encontrada"


def test_speech_sample_invalid_filename() -> None:
    """Verifica HTTP 400 ante nombres de archivo con secuencias peligrosas."""
    for bad_name in ("..evil.wav", "bad;audio.wav"):
        response = client.get(f"/api/v1/speech/sample/{bad_name}")
        assert response.status_code == 400
        assert response.json()["detail"] == "Nombre de archivo inválido"

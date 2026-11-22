"""API base de microservicios para la Plataforma de Aprendizaje de Lenguas Maternas e Indígenas."""

import io
import re
import wave

from fastapi import FastAPI, HTTPException, Response
from fastapi.responses import JSONResponse

app = FastAPI(
    title="app",
    description=(
        "Plataforma de aprendizaje gamificado de lenguas maternas e indígenas "
        "(Náhuatl, Maya Yucateco, Zapoteco, Mixteco y Tsotsil)."
    ),
    version="1.0.0",
)

_APP_READY = True
_FILENAME_PATTERN = re.compile(r"^[a-zA-Z0-9._-]+$")


def _build_silent_wav_bytes(duration_ms: int = 120, sample_rate: int = 16000) -> bytes:
    """Genera un archivo WAV PCM válido en memoria para muestras de audio nativo."""
    num_frames = int(sample_rate * duration_ms / 1000)
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(sample_rate)
        wav_file.writeframes(b"\x00\x00" * num_frames)
    return buffer.getvalue()


SPEECH_SAMPLES: dict[str, bytes] = {
    "cualli-tonalli.wav": _build_silent_wav_bytes(),
    "tlazohcamati.wav": _build_silent_wav_bytes(),
    "niltze.wav": _build_silent_wav_bytes(),
    "ma-cualli-tonalli.wav": _build_silent_wav_bytes(),
}

NAHUATL_UNIT_1_LESSON: dict[str, object] = {
    "lesson_id": "nahuatl-unidad-1",
    "language": "Náhuatl",
    "iso_639_3": "nhn",
    "unit": "unidad-1",
    "title": "Saludos y cortesía (Tlapaloliztli)",
    "encoding": "UTF-8",
    "supported_languages": [
        "Náhuatl",
        "Maya Yucateco",
        "Zapoteco",
        "Mixteco",
        "Tsotsil",
    ],
    "items": [
        {
            "id": "nah-001",
            "term": "Cualli tōnalli",
            "ipa": "/ˈkwalːi toːˈnalːi/",
            "translation": "Buenos días",
            "notes": "Saludo matutino tradicional con vocal larga marcada con macrón (ō).",
            "audio_url": "/api/v1/speech/sample/cualli-tonalli.wav",
        },
        {
            "id": "nah-002",
            "term": "Tlazōhcamati",
            "ipa": "/tɬasoːʔˈkamati/",
            "translation": "Gracias",
            "notes": "Expresión de gratitud con consonante fricativa lateral (tl) y vocal larga (ō).",
            "audio_url": "/api/v1/speech/sample/tlazohcamati.wav",
        },
        {
            "id": "nah-003",
            "term": "Niltze, ¿quēn timoyetzticaꞌ?",
            "ipa": "/ˈniltse keːn timojetsˈtikaʔ/",
            "translation": "Hola, ¿cómo estás?",
            "notes": "Incluye salto glotal representado mediante saltillo (ꞌ) y macrón (ē).",
            "audio_url": "/api/v1/speech/sample/niltze.wav",
        },
        {
            "id": "nah-004",
            "term": "Mā cualli tōnalli",
            "ipa": "/maː ˈkwalːi toːˈnalːi/",
            "translation": "Que tengas buen día",
            "notes": "Partícula optativa con vocal larga (ā) y acentuación diacrítica.",
            "audio_url": "/api/v1/speech/sample/ma-cualli-tonalli.wav",
        },
    ],
    "exercises": [
        {
            "id": "ex-001",
            "type": "translation",
            "prompt": "Traduce al español: Cualli tōnalli",
            "expected_answer": "Buenos días",
            "xp": 15,
        },
        {
            "id": "ex-002",
            "type": "listening",
            "prompt": "Escucha el audio nativo y selecciona la frase correcta.",
            "audio_url": "/api/v1/speech/sample/tlazohcamati.wav",
            "options": ["Tlazōhcamati", "Cualli tōnalli", "Mā cualli tōnalli"],
            "expected_answer": "Tlazōhcamati",
            "xp": 20,
        },
        {
            "id": "ex-003",
            "type": "phonetics",
            "prompt": "Pronuncia claramente el cierre glotal en: Niltze, ¿quēn timoyetzticaꞌ?",
            "target_phrase": "Niltze, ¿quēn timoyetzticaꞌ?",
            "min_similarity": 0.80,
            "xp": 25,
        },
    ],
}


@app.get("/healthz")
async def healthz() -> JSONResponse:
    """Sonda de vida (liveness) para Kubernetes."""
    return JSONResponse(
        content={"status": "ok", "service": "app"},
        media_type="application/json; charset=utf-8",
    )


@app.get("/ready")
async def ready() -> JSONResponse:
    """Sonda de disponibilidad (readiness) para tráfico en producción y liberación."""
    if not _APP_READY:
        return JSONResponse(
            status_code=503,
            content={"status": "not_ready", "service": "app"},
            media_type="application/json; charset=utf-8",
        )
    return JSONResponse(
        content={
            "status": "ready",
            "service": "app",
            "checks": {
                "lessons_catalog": "ok",
                "speech_samples": "ok",
            },
        },
        media_type="application/json; charset=utf-8",
    )


@app.get("/api/v1/lessons/nahuatl/unidad-1")
async def get_nahuatl_unit_1() -> JSONResponse:
    """Devuelve la micro-lección Unidad 1 de Náhuatl con soporte íntegro UTF-8."""
    return JSONResponse(
        content=NAHUATL_UNIT_1_LESSON,
        media_type="application/json; charset=utf-8",
    )


@app.api_route("/api/v1/speech/sample/{filename}", methods=["GET", "HEAD"])
async def get_speech_sample(filename: str) -> Response:
    """Sirve muestras de audio nativo en formato WAV con validación estricta de nombre."""
    if ".." in filename or "/" in filename or "\\" in filename or not _FILENAME_PATTERN.fullmatch(filename):
        raise HTTPException(status_code=400, detail="Nombre de archivo inválido")

    audio_bytes = SPEECH_SAMPLES.get(filename)
    if audio_bytes is None:
        raise HTTPException(status_code=404, detail="Muestra de audio no encontrada")

    return Response(
        content=audio_bytes,
        media_type="audio/wav",
        headers={
            "X-Audio-Language": "nahuatl",
            "X-Content-Type-Options": "nosniff",
            "Cache-Control": "public, max-age=3600",
        },
    )

import asyncio
import gc
import logging
import os
import tempfile
import time
from contextlib import asynccontextmanager, suppress
from pathlib import Path
from typing import Any, Optional

import whisper
from fastapi import FastAPI, File, Form, Header, HTTPException, UploadFile
from fastapi.responses import JSONResponse, PlainTextResponse

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO").upper())
logger = logging.getLogger("server_whisper")

SUPPORTED_RESPONSE_FORMATS = {"json", "text", "verbose_json", "srt", "vtt"}


def _read_idle_timeout() -> float:
    raw_value = os.getenv("MODEL_IDLE_UNLOAD_SECONDS", "300")
    try:
        return float(raw_value)
    except ValueError:
        logger.warning(
            "Invalid MODEL_IDLE_UNLOAD_SECONDS=%r; defaulting to 300 seconds.", raw_value
        )
        return 300.0


def _resolve_whisper_device() -> str:
    configured_device = os.getenv("WHISPER_DEVICE")
    if configured_device is not None:
        normalized = configured_device.strip()
        if normalized:
            if normalized.lower() == "auto":
                logger.info("WHISPER_DEVICE=auto; falling back to CUDA auto-detection.")
            else:
                logger.info("Using WHISPER_DEVICE override: %s", normalized)
                return normalized
        else:
            logger.warning("WHISPER_DEVICE is empty; falling back to CUDA auto-detection.")

    try:
        import torch

        if torch.cuda.is_available():
            logger.info("CUDA detected; using 'cuda' device for Whisper.")
            return "cuda"
    except Exception as exc:
        logger.warning(
            "Could not check CUDA availability (%s); defaulting Whisper to CPU.",
            exc,
        )

    logger.info("CUDA not available; using 'cpu' device for Whisper.")
    return "cpu"


def _parse_bearer_token(authorization_header: Optional[str]) -> Optional[str]:
    if not authorization_header:
        return None

    scheme, _, token = authorization_header.partition(" ")
    if scheme.lower() != "bearer" or not token:
        return None
    return token.strip()


def _enforce_auth(authorization_header: Optional[str]) -> None:
    expected_api_key = os.getenv("API_KEY")
    if not expected_api_key:
        return

    supplied_token = _parse_bearer_token(authorization_header)
    if supplied_token != expected_api_key:
        raise HTTPException(
            status_code=401,
            detail={
                "message": "Invalid API key.",
                "type": "invalid_request_error",
                "param": None,
                "code": "invalid_api_key",
            },
            headers={"WWW-Authenticate": "Bearer"},
        )


def _normalize_response_format(response_format: Optional[str]) -> str:
    normalized = (response_format or "json").strip().lower()
    if not normalized:
        return "json"
    if normalized not in SUPPORTED_RESPONSE_FORMATS:
        allowed = ", ".join(sorted(SUPPORTED_RESPONSE_FORMATS))
        raise HTTPException(
            status_code=400,
            detail={
                "message": f"Unsupported response_format '{normalized}'. Allowed: {allowed}.",
                "type": "invalid_request_error",
                "param": "response_format",
                "code": None,
            },
        )
    return normalized


def _resolve_model_name(model_name: str) -> str:
    normalized = model_name.strip()
    if not normalized:
        raise HTTPException(
            status_code=400,
            detail={
                "message": "The 'model' field is required.",
                "type": "invalid_request_error",
                "param": "model",
                "code": None,
            },
        )

    # OpenAI clients commonly send whisper-1; map that to a local default model.
    if normalized == "whisper-1":
        return os.getenv("WHISPER_MODEL", "base")
    return normalized


def _to_builtin(value: Any) -> Any:
    if isinstance(value, dict):
        return {k: _to_builtin(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_to_builtin(item) for item in value]
    if isinstance(value, tuple):
        return [_to_builtin(item) for item in value]
    if hasattr(value, "item") and callable(getattr(value, "item")):
        try:
            return value.item()
        except Exception:
            return value
    return value


def _seconds_to_timestamp(total_seconds: Any, decimal_marker: str) -> str:
    try:
        seconds = max(0.0, float(total_seconds))
    except (TypeError, ValueError):
        seconds = 0.0

    milliseconds = round(seconds * 1000)
    hours = milliseconds // 3_600_000
    milliseconds -= hours * 3_600_000
    minutes = milliseconds // 60_000
    milliseconds -= minutes * 60_000
    secs = milliseconds // 1000
    milliseconds -= secs * 1000
    return f"{hours:02d}:{minutes:02d}:{secs:02d}{decimal_marker}{milliseconds:03d}"


def _segments_to_srt(segments: list[dict[str, Any]]) -> str:
    blocks = []
    for index, segment in enumerate(segments, start=1):
        start = _seconds_to_timestamp(segment.get("start"), ",")
        end = _seconds_to_timestamp(segment.get("end"), ",")
        text = str(segment.get("text", "")).strip()
        blocks.append(f"{index}\n{start} --> {end}\n{text}")

    if not blocks:
        return ""
    return "\n\n".join(blocks) + "\n"


def _segments_to_vtt(segments: list[dict[str, Any]]) -> str:
    lines = ["WEBVTT", ""]
    for segment in segments:
        start = _seconds_to_timestamp(segment.get("start"), ".")
        end = _seconds_to_timestamp(segment.get("end"), ".")
        text = str(segment.get("text", "")).strip()
        lines.append(f"{start} --> {end}")
        lines.append(text)
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def _transcribe_file(
    model: Any,
    audio_path: str,
    language: Optional[str],
    prompt: Optional[str],
    temperature: Optional[float],
) -> dict[str, Any]:
    options: dict[str, Any] = {}
    if language:
        options["language"] = language
    if prompt:
        options["initial_prompt"] = prompt
    if temperature is not None:
        options["temperature"] = temperature

    model_device = str(getattr(model, "device", "")).lower()
    if model_device == "cpu":
        options.setdefault("fp16", False)

    result = model.transcribe(audio_path, **options)
    return _to_builtin(result)


async def _write_upload_to_temp(upload_file: UploadFile) -> str:
    suffix = Path(upload_file.filename or "audio").suffix
    with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp_file:
        while True:
            chunk = await upload_file.read(1024 * 1024)
            if not chunk:
                break
            tmp_file.write(chunk)
        return tmp_file.name


class WhisperModelManager:
    def __init__(self, idle_unload_seconds: float) -> None:
        self._idle_unload_seconds = idle_unload_seconds
        self._lock = asyncio.Lock()
        self._model: Any = None
        self._model_name: Optional[str] = None
        self._active_requests = 0
        self._last_activity = time.monotonic()

    def _load_model_sync(self, model_name: str) -> Any:
        device = _resolve_whisper_device()
        return whisper.load_model(model_name, device=device)

    def _unload_model_locked(self) -> None:
        if self._model is None:
            return

        logger.info("Unloading Whisper model '%s'.", self._model_name)
        self._model = None
        self._model_name = None
        gc.collect()

        try:
            import torch

            if torch.cuda.is_available():
                torch.cuda.empty_cache()
            if hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
                torch.mps.empty_cache()
        except Exception:
            pass

    async def acquire(self, model_name: str) -> Any:
        async with self._lock:
            self._active_requests += 1
            self._last_activity = time.monotonic()
            try:
                if self._model is None or self._model_name != model_name:
                    if self._model_name and self._model_name != model_name:
                        logger.info(
                            "Switching Whisper model from '%s' to '%s'.",
                            self._model_name,
                            model_name,
                        )
                    logger.info("Loading Whisper model '%s'.", model_name)
                    self._unload_model_locked()
                    self._model = await asyncio.to_thread(self._load_model_sync, model_name)
                    self._model_name = model_name
                return self._model
            except Exception:
                self._active_requests = max(0, self._active_requests - 1)
                self._last_activity = time.monotonic()
                raise

    async def release(self) -> None:
        async with self._lock:
            if self._active_requests > 0:
                self._active_requests -= 1
            if self._active_requests == 0:
                self._last_activity = time.monotonic()

    async def unload_if_idle(self) -> None:
        if self._idle_unload_seconds < 0:
            return

        async with self._lock:
            if self._model is None:
                return
            if self._active_requests != 0:
                return

            idle_duration = time.monotonic() - self._last_activity
            if idle_duration >= self._idle_unload_seconds:
                self._unload_model_locked()

    async def force_unload(self) -> None:
        async with self._lock:
            self._unload_model_locked()


model_manager = WhisperModelManager(idle_unload_seconds=_read_idle_timeout())


async def _idle_unload_loop() -> None:
    while True:
        await asyncio.sleep(1.0)
        await model_manager.unload_if_idle()


@asynccontextmanager
async def lifespan(_: FastAPI):
    idle_task = asyncio.create_task(_idle_unload_loop())
    try:
        yield
    finally:
        idle_task.cancel()
        with suppress(asyncio.CancelledError):
            await idle_task
        await model_manager.force_unload()


app = FastAPI(title="Local Whisper Transcription Server", lifespan=lifespan)


@app.exception_handler(HTTPException)
async def openai_http_exception_handler(_, exc: HTTPException):
    if isinstance(exc.detail, dict) and "message" in exc.detail:
        payload = {"error": exc.detail}
    else:
        payload = {
            "error": {
                "message": str(exc.detail),
                "type": "invalid_request_error",
                "param": None,
                "code": None,
            }
        }

    return JSONResponse(status_code=exc.status_code, content=payload, headers=exc.headers)


@app.post("/v1/audio/transcriptions")
async def create_audio_transcription(
    file: UploadFile = File(...),
    model: str = Form(...),
    language: Optional[str] = Form(None),
    prompt: Optional[str] = Form(None),
    temperature: Optional[float] = Form(None),
    response_format: Optional[str] = Form(None),
    authorization: Optional[str] = Header(default=None),
):
    _enforce_auth(authorization)

    requested_model = _resolve_model_name(model)
    desired_response_format = _normalize_response_format(response_format)
    language = language.strip() if language else None
    prompt = prompt.strip() if prompt else None

    temp_audio_path: Optional[str] = None
    acquired_model = False

    try:
        temp_audio_path = await _write_upload_to_temp(file)
        if os.path.getsize(temp_audio_path) == 0:
            raise HTTPException(
                status_code=400,
                detail={
                    "message": "Uploaded file is empty.",
                    "type": "invalid_request_error",
                    "param": "file",
                    "code": None,
                },
            )

        loaded_model = await model_manager.acquire(requested_model)
        acquired_model = True
        transcription = await asyncio.to_thread(
            _transcribe_file,
            loaded_model,
            temp_audio_path,
            language,
            prompt,
            temperature,
        )
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(
            status_code=500,
            detail={
                "message": f"Transcription failed: {exc}",
                "type": "server_error",
                "param": None,
                "code": None,
            },
        ) from exc
    finally:
        if acquired_model:
            await model_manager.release()
        if temp_audio_path and os.path.exists(temp_audio_path):
            os.unlink(temp_audio_path)
        await file.close()

    text_output = str(transcription.get("text", "")).strip()

    if desired_response_format == "text":
        return PlainTextResponse(text_output, media_type="text/plain; charset=utf-8")

    if desired_response_format == "json":
        return JSONResponse({"text": text_output})

    segments = transcription.get("segments") or []
    if not isinstance(segments, list):
        segments = []
    segments = [_to_builtin(segment) for segment in segments]

    if desired_response_format == "verbose_json":
        return JSONResponse(
            {
                "text": text_output,
                "segments": segments,
                "language": transcription.get("language") or language,
            }
        )

    if desired_response_format == "srt":
        return PlainTextResponse(
            _segments_to_srt(segments),
            media_type="application/x-subrip; charset=utf-8",
        )

    if desired_response_format == "vtt":
        return PlainTextResponse(
            _segments_to_vtt(segments),
            media_type="text/vtt; charset=utf-8",
        )

    return JSONResponse({"text": text_output})


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        app,
        host=os.getenv("HOST", "0.0.0.0"),
        port=int(os.getenv("PORT", "11002")),
    )

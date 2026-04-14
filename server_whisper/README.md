# Local Whisper OpenAI-Compatible Server

This folder contains a FastAPI server that is compatible with OpenAI-style transcription clients.

Endpoint contract:

- `POST /v1/audio/transcriptions`
- multipart form-data:
  - required: `file`, `model`
  - optional: `language`, `prompt`, `temperature`, `response_format`
- supported `response_format` values:
  - `json` (default) -> `{"text": "..."}`
  - `text` -> plain text
  - `verbose_json` -> includes `text`, `segments`, `language`
  - `srt` / `vtt` -> subtitle text

## Environment variables

- `API_KEY` (optional): if set, require `Authorization: Bearer <API_KEY>`.
- `MODEL_IDLE_UNLOAD_SECONDS` (optional, default `300`): unload model after this idle time.
- `WHISPER_MODEL` (optional, default `base`): local model used when request sends `model=whisper-1`.
- `WHISPER_DEVICE` (optional):
  - if set (for example `cpu`, `cuda`, `cuda:0`), server uses it directly
  - if unset or set to `auto`, server chooses `cuda` when available, otherwise `cpu`
- `HOST` (optional, default `0.0.0.0`)
- `PORT` (optional, default `11002`)

## Ubuntu native setup

1. Install system dependencies:

```bash
sudo apt update
sudo apt install -y python3 python3-venv python3-pip ffmpeg
```

2. From repo root, create and populate a virtual environment:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -r server_whisper/requirements.txt
```

3. Start server:

```bash
source .venv/bin/activate
HOST=0.0.0.0 PORT=11002 python server_whisper/server.py
```

## Run permanently with systemd (Ubuntu)

Create `/etc/systemd/system/whisper-transcribe.service`:

```ini
[Unit]
Description=Local Whisper transcription server
After=network.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/absolute/path/to/transcribe-app
Environment=HOST=0.0.0.0
Environment=PORT=11002
Environment=MODEL_IDLE_UNLOAD_SECONDS=300
Environment=WHISPER_MODEL=base
Environment=API_KEY=my-secret
# Optional explicit device (cpu, cuda, cuda:0, auto)
Environment=WHISPER_DEVICE=auto
ExecStart=/absolute/path/to/transcribe-app/.venv/bin/python /absolute/path/to/transcribe-app/server_whisper/server.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

Enable + start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now whisper-transcribe
sudo systemctl status whisper-transcribe
```

Update service env/config and restart:

```bash
sudo systemctl restart whisper-transcribe
```

## CUDA notes

- Device selection priority is:
  1. `WHISPER_DEVICE` (if explicitly set and not empty)
  2. auto-detected CUDA (`torch.cuda.is_available()`)
  3. CPU fallback
- For GPU use, ensure NVIDIA driver/toolkit are installed on host and your Python environment/container has a CUDA-enabled PyTorch build.

## Docker

Build image (from repo root):

```bash
docker build -f server_whisper/Dockerfile -t whisper-server:latest server_whisper
```

Run on CPU:

```bash
docker run -d \
  --name whisper-server-cpu \
  --restart unless-stopped \
  -p 11002:11002 \
  -e API_KEY=my-secret \
  -e MODEL_IDLE_UNLOAD_SECONDS=300 \
  whisper-server:latest
```

Run on NVIDIA GPU host:

```bash
docker run -d \
  --name whisper-server-gpu \
  --restart unless-stopped \
  --gpus all \
  -p 11002:11002 \
  -e API_KEY=my-secret \
  -e WHISPER_DEVICE=cuda \
  -e MODEL_IDLE_UNLOAD_SECONDS=300 \
  whisper-server:latest
```

If your Docker setup uses legacy NVIDIA runtime syntax, replace `--gpus all` with `--runtime=nvidia`.

## Idle unload and memory release

The server keeps lazy model lifecycle behavior:

- model loads only when the first transcription request arrives
- model unloads after idle timeout when no active requests remain
- on unload, server runs Python garbage collection and attempts to release accelerator caches (CUDA/MPS), helping return memory to the system

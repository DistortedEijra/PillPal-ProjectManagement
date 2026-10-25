---
title: PillPal OCR
emoji: 💊
colorFrom: blue
colorTo: indigo
sdk: docker
app_port: 7860
pinned: false
license: mit
---

# PillPal OCR server

Reads handwritten prescriptions for PillPal's Scan-to-Schedule feature, using the
Donut model [chinmays18/medical-prescription-ocr](https://huggingface.co/chinmays18/medical-prescription-ocr)
(MIT license). The model is not validated for clinical use, so the app always asks
the user to check the details before saving.

## Run it on a laptop (free)
1. Install Python 3.11 or 3.12 from python.org (tick "Add python.exe to PATH").
2. Double-click `run_server.bat`. The first run installs the libraries and downloads
   the model (about 800 MB), so it takes a while. Wait for "Application startup complete".
3. If Windows Firewall asks, allow access on Private networks.
4. Connect the phone to the same Wi-Fi as the laptop. School Wi-Fi often blocks
   phone-to-laptop connections; if so, turn on the phone's hotspot and connect the
   laptop to it, then run `run_server.bat` again to see the new IP address.
5. In PillPal: Add Schedule → tap the gear next to "Handwritten prescription" →
   enter `http://<laptop IPv4 address>:7860` → Test → Save.

## Endpoints
- `GET /` — health check: `{"status": "ok", "model_loaded": true}`
- `POST /ocr` — form field `image` (a photo, max 10 MB) → `{"text": "...", "seconds": 12.3}`

Optional: set an environment variable `API_KEY`. Requests must then send it in the
`X-API-Key` header (set the same value in `lib/ocr_config.dart`).

## Hosting online (paid)
The `Dockerfile` works on a Hugging Face Docker Space or any Docker host, but since
mid-2026 Hugging Face charges for Docker and CPU Gradio Spaces.

Use test prescriptions only, not real patient data.

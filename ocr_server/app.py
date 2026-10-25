"""PillPal handwritten prescription OCR server.

Runs the Donut model chinmays18/medical-prescription-ocr and returns the text it
reads from a prescription photo. The PillPal app sends the photo to POST /ocr and
then pulls the medicine name, dosage, and times out of the text itself.

Endpoints
  GET  /     -> {"status": "ok", "model_loaded": true}
  POST /ocr  -> multipart form with an "image" file -> {"text": "...", "seconds": 12.3}

Optional: set a Space secret named API_KEY. The app must then send the same value
in the X-API-Key header.
"""

import io
import os
import threading
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, File, Header, HTTPException, UploadFile
from PIL import Image, ImageOps, UnidentifiedImageError

MODEL_ID = os.environ.get("MODEL_ID", "chinmays18/medical-prescription-ocr")
TASK_PROMPT = "<s_ocr>"
MAX_UPLOAD_BYTES = 10 * 1024 * 1024  # 10 MB
API_KEY = os.environ.get("API_KEY", "").strip()

_state = {}
_lock = threading.Lock()  # one image at a time; the free CPU can't run two at once


def load_model():
    import torch
    from transformers import DonutProcessor, VisionEncoderDecoderModel

    torch.set_num_threads(max(1, os.cpu_count() or 1))
    processor = DonutProcessor.from_pretrained(MODEL_ID)
    model = VisionEncoderDecoderModel.from_pretrained(MODEL_ID)
    model.eval()
    _state["processor"] = processor
    _state["model"] = model
    _state["start_id"] = processor.tokenizer.convert_tokens_to_ids(TASK_PROMPT)


def run_ocr(image: Image.Image) -> str:
    """Same steps as the model author's own app: <s_ocr> is the decoder start token."""
    import torch

    processor = _state["processor"]
    model = _state["model"]
    pixel_values = processor(images=image, return_tensors="pt").pixel_values
    with torch.inference_mode():
        ids = model.generate(
            pixel_values,
            max_length=512,
            num_beams=1,
            decoder_start_token_id=_state["start_id"],
        )
    text = processor.tokenizer.batch_decode(ids, skip_special_tokens=True)[0]
    return text.replace(TASK_PROMPT, "").replace("</s>", "").strip()


@asynccontextmanager
async def lifespan(_app: FastAPI):
    load_model()
    yield


app = FastAPI(title="PillPal OCR", lifespan=lifespan)


@app.get("/")
def health():
    return {"status": "ok", "model_loaded": "model" in _state}


@app.post("/ocr")
def ocr(image: UploadFile = File(...), x_api_key: str | None = Header(default=None)):
    if API_KEY and x_api_key != API_KEY:
        raise HTTPException(status_code=401, detail="Wrong or missing API key.")

    data = image.file.read(MAX_UPLOAD_BYTES + 1)
    if not data:
        raise HTTPException(status_code=400, detail="The image is empty.")
    if len(data) > MAX_UPLOAD_BYTES:
        raise HTTPException(status_code=413, detail="The image is larger than 10 MB.")
    try:
        img = Image.open(io.BytesIO(data))
        img = ImageOps.exif_transpose(img).convert("RGB")  # phone photos are often rotated
    except (UnidentifiedImageError, OSError):
        raise HTTPException(status_code=400, detail="The file is not a readable image.")

    started = time.time()
    with _lock:
        text = run_ocr(img)
    return {"text": text, "seconds": round(time.time() - started, 1)}

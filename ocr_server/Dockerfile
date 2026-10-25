FROM python:3.11-slim

# Hugging Face Spaces run the container as user 1000
RUN useradd -m -u 1000 user
USER user
ENV HOME=/home/user \
    PATH=/home/user/.local/bin:$PATH \
    HF_HOME=/home/user/.cache/huggingface \
    PYTHONUNBUFFERED=1
WORKDIR $HOME/app

COPY --chown=user requirements.txt .
RUN pip install --no-cache-dir --upgrade -r requirements.txt

# Download the model (~800 MB) while building, so the server starts faster
RUN python -c "from transformers import DonutProcessor, VisionEncoderDecoderModel as M; \
m='chinmays18/medical-prescription-ocr'; DonutProcessor.from_pretrained(m); M.from_pretrained(m)"

COPY --chown=user app.py .

EXPOSE 7860
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "7860"]

FROM python:3.12-slim AS builder

WORKDIR /build

COPY requirements.txt .

RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir --no-compile -r requirements.txt \
    && /opt/venv/bin/pip uninstall -y pip

FROM python:3.12-slim

ENV PATH="/opt/venv/bin:$PATH" PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 FETCHER_HOST=0.0.0.0 FETCHER_PORT=8001

WORKDIR /app

RUN addgroup --system app && adduser --system --ingroup app app

COPY --from=builder --chown=app:app /opt/venv /opt/venv
COPY --chown=app:app __init__.py __main__.py app.py config.py provider.py worker.py ./fetcher/

USER app

EXPOSE 8001

CMD ["python", "-m", "fetcher"]

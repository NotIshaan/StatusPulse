# -------- Builder Stage --------
FROM python:3.11-alpine AS builder

WORKDIR /app

# Install build dependencies for Alpine
RUN apk add --no-cache gcc musl-dev postgresql-dev

COPY app/requirements.txt .

RUN pip install --user --no-cache-dir -r requirements.txt

# -------- Runtime Stage --------
FROM python:3.11-alpine

WORKDIR /app

# Install runtime postgres library and create user
RUN apk add --no-cache libpq && adduser -D appuser

# Copy dependencies
COPY --from=builder /root/.local /home/appuser/.local

# Copy app
COPY app/ .

ENV PATH=/home/appuser/.local/bin:$PATH

USER appuser

EXPOSE 8000

# Healthcheck
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health').read()"

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]

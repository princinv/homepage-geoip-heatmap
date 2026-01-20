# Dockerfile
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    APP_PORT=8000

WORKDIR /app

# Create a non-root user
RUN useradd -r -u 10001 -g users appuser

# Install deps
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

# Copy source
COPY src/ /app/

EXPOSE 8000

USER appuser

# Use sh so ${APP_PORT} is expanded at runtime
CMD ["sh", "-c", "uvicorn app:APP --host 0.0.0.0 --port ${APP_PORT}"]

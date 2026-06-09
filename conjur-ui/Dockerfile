FROM python:3.12-slim AS builder
WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.12-slim
RUN groupadd -r appuser && useradd -r -g appuser -d /app appuser
WORKDIR /app
COPY --from=builder /install /usr/local
COPY --chown=appuser:appuser . .
USER appuser
EXPOSE 8080
CMD ["gunicorn","--workers","2","--bind","0.0.0.0:8080","--access-logfile","-","--error-logfile","-","--log-level","debug","--env","SCRIPT_NAME=/ui","app:app"]

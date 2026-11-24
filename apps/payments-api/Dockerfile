FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080 \
    APP_VERSION=1.0.0

RUN groupadd --gid 10001 app \
    && useradd --uid 10001 --gid 10001 --shell /usr/sbin/nologin --no-create-home app

WORKDIR /app
COPY --chown=10001:10001 app.py /app/app.py

USER 10001:10001
EXPOSE 8080

CMD ["python", "/app/app.py"]

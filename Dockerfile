# syntax=docker/dockerfile:1
FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim AS builder

WORKDIR /app

ENV UV_COMPILE_BYTECODE=1
ENV UV_LINK_MODE=copy

RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install --no-install-recommends -y \
    build-essential \
    git \
    npm \
    gcc \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY . /app/

RUN --mount=type=cache,id=uv-cache,target=/root/.cache/uv \
    uv sync --frozen --no-editable

FROM python:3.12.3-slim AS runtime

RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y curl \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && useradd user -u 1000 -g 0 --no-create-home --home-dir /app/data \
    && mkdir /data && chown -R 1000:0 /data

COPY --from=builder --chown=1000 /app/.venv /app/.venv
COPY --from=builder --chown=1000 /app /app

ENV PATH="/app/.venv/bin:$PATH"
ENV PORT=${PORT:-7860}
ENV HOST=0.0.0.0
ENV PYTHONUNBUFFERED=1
ENV LANGFLOW_HOST=0.0.0.0

EXPOSE ${PORT}

USER 1000

CMD langflow run --host 0.0.0.0 --port ${PORT}

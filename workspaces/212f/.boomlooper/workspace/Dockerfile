FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# System libs: Django stack + build toolchain, plus Node 22 + pnpm so one
# image can run both the JS dev servers and the Django API.
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential git curl bash ca-certificates pkg-config gnupg \
      libpq-dev libxml2-dev libxslt-dev libffi-dev libssl-dev libxmlsec1-dev libxmlsec1-openssl \
      libjpeg-dev zlib1g-dev \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && corepack enable \
    && corepack prepare pnpm@10.32.1 --activate \
    && rm -rf /var/lib/apt/lists/*

# Python venv outside /workspace so the mounted code volume can't shadow it.
ENV VIRTUAL_ENV=/opt/venv
RUN python -m venv $VIRTUAL_ENV
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

ENV PNPM_HOME=/pnpm
ENV PATH="$PNPM_HOME:$PATH"
RUN mkdir -p /pnpm

WORKDIR /workspace

FROM python:3.12-slim

# System deps for Python packages (postgres, xml, crypto) and general tools
RUN apt-get update && apt-get install -y \
    bash git curl wget build-essential \
    libpq-dev libxml2-dev libxslt1-dev libffi-dev \
    pkg-config iproute2 procps \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 22.x
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# Enable corepack for pnpm
RUN corepack enable && corepack enable pnpm

WORKDIR /workspace

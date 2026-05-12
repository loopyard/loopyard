FROM golang:1.26-bookworm

ENV DEBIAN_FRONTEND=noninteractive
ENV PNPM_HOME=/usr/local/pnpm
ENV PATH=$PNPM_HOME:$PATH

RUN apt-get update && apt-get install -y \
    git curl ca-certificates build-essential \
    sqlite3 libsqlite3-dev pkg-config \
    python3 python3-venv \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
 && apt-get install -y nodejs \
 && rm -rf /var/lib/apt/lists/*

RUN npm install -g corepack@latest \
 && corepack enable \
 && corepack prepare pnpm@10.33.0 --activate

RUN groupadd -g 1000 gitea && useradd -u 1000 -g 1000 -m -s /bin/bash gitea

WORKDIR /workspace

FROM golang:1.26-bookworm

# Install Node.js 22 and system deps
RUN apt-get update && apt-get install -y \
    git \
    curl \
    build-essential \
    sqlite3 \
    libsqlite3-dev \
    libpam0g-dev \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 22
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install pnpm
RUN corepack enable && corepack prepare pnpm@10.33.0 --activate

# Create non-root user (Gitea refuses to run as root)
RUN useradd -m -s /bin/bash -u 1000 gitea
ENV HOME=/home/gitea
ENV GOPATH=/home/gitea/go
ENV PATH=$GOPATH/bin:/usr/local/go/bin:$PATH

WORKDIR /workspace

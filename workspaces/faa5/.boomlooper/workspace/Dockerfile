# === Dev stage ===
FROM ruby:3.4.8-slim AS dev

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential git curl \
      libpq-dev postgresql-client \
      libproj-dev proj-bin \
      libyaml-dev pkg-config \
      libvips imagemagick libwebp-dev \
      ffmpeg libidn-dev libidn12 \
      nodejs npm \
      procps && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
RUN gem install bundler
EXPOSE 3000
CMD ["sleep", "infinity"]

# === Postgres + PostGIS + pgvector stage ===
FROM postgis/postgis:17-3.4 AS postgres

# Install pgvector from source (needs llvm-13 + clang-13 to match PG's JIT toolchain)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      build-essential postgresql-server-dev-17 git ca-certificates \
      clang-13 llvm-13 llvm-13-dev && \
    cd /tmp && \
    git clone --branch v0.8.0 https://github.com/pgvector/pgvector.git && \
    cd pgvector && \
    make USE_PGXS=1 && \
    make USE_PGXS=1 install && \
    cd / && rm -rf /tmp/pgvector && \
    apt-get remove -y build-essential postgresql-server-dev-17 git clang-13 llvm-13 llvm-13-dev && \
    apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/*

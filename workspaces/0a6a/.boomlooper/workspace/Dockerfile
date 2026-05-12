### --- Postgres with PostGIS + pgvector ---
FROM postgis/postgis:17-3.4 AS postgres

RUN apt-get update && apt-get install -y --no-install-recommends \
    postgresql-17-pgvector \
    && rm -rf /var/lib/apt/lists/*

### --- Rails dev image ---
FROM ruby:3.4.8-slim AS dev

# System deps for pg, postgis adapter, nodejs, native gems
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libpq-dev \
    libgeos-dev \
    libproj-dev \
    gdal-bin \
    libgdal-dev \
    nodejs \
    npm \
    git \
    curl \
    libvips-dev \
    libyaml-dev \
    libidn-dev \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

RUN gem install bundler

CMD ["sleep", "infinity"]

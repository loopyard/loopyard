FROM ruby:3.4.8-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential git curl ca-certificates gnupg pkg-config cmake \
      libpq-dev libyaml-dev libxml2-dev libxslt-dev libssl-dev zlib1g-dev \
      libjemalloc-dev \
      postgresql-client \
      advancecomp gifsicle jpegoptim optipng pngcrush pngquant jhead \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g pnpm@10.28.0

ENV BUNDLE_PATH=/usr/local/bundle
WORKDIR /workspace

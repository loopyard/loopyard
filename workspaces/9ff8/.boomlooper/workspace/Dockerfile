FROM ruby:3.4.4-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    build-essential git curl gnupg ca-certificates \
    libpq-dev libyaml-dev pkg-config \
    libxml2-dev libxslt1-dev \
    libvips libvips-dev \
    libprotobuf-dev protobuf-compiler \
    libssl-dev libffi-dev \
    libpcap-dev \
    postgresql-client \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && corepack enable \
    && corepack prepare pnpm@10.2.0 --activate

RUN gem install foreman

ENV BUNDLE_PATH=/usr/local/bundle
ENV PATH=/usr/local/bundle/bin:$PATH

WORKDIR /workspace

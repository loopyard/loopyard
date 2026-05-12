FROM ruby:3.4.4-slim

RUN apt-get update && apt-get install -y \
    build-essential git curl pkg-config \
    libpq-dev libyaml-dev libvips \
    nodejs npm \
    && rm -rf /var/lib/apt/lists/*

RUN gem install foreman

ENV BUNDLE_PATH=/usr/local/bundle
WORKDIR /workspace

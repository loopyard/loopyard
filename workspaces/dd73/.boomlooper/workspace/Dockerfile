FROM ruby:3.4.4-slim

# System dependencies for Rails, pg, image_processing, grpc, cld3, etc.
RUN apt-get update && apt-get install -y \
    build-essential \
    git \
    curl \
    libpq-dev \
    libvips-dev \
    libprotobuf-dev \
    protobuf-compiler \
    shared-mime-info \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 24 and pnpm
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && corepack enable && corepack prepare pnpm@10.2.0 --activate

# Install foreman for Procfile.dev
RUN gem install foreman

WORKDIR /workspace

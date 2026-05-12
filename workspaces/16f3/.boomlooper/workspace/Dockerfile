FROM ruby:3.4-slim

# System dependencies for Discourse
RUN apt-get update && apt-get install -y \
    git curl build-essential pkg-config \
    libpq-dev \
    libxml2-dev libxslt1-dev \
    libyaml-dev \
    imagemagick libmagickwand-dev \
    libjemalloc2 \
    optipng pngquant jhead jpegoptim gifsicle \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 22
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install pnpm
RUN npm install -g pnpm@10

WORKDIR /workspace

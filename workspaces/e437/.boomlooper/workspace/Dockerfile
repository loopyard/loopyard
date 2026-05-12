FROM node:20-slim

RUN apt-get update && apt-get install -y \
    git curl build-essential python3 \
    && rm -rf /var/lib/apt/lists/*

# Enable corepack for Yarn 4
RUN corepack enable && corepack prepare yarn@4.12.0 --activate

WORKDIR /workspace

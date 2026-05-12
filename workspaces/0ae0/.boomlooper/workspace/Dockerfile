FROM node:22-slim

RUN apt-get update && apt-get install -y \
    git curl ca-certificates openssl python3 build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

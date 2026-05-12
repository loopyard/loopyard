FROM alpine:latest

RUN apk add --no-cache \
    elixir erlang erlang-dev \
    build-base git curl inotify-tools nodejs npm bash

ENV MIX_HOME=/workspace/.mix_home HEX_HOME=/workspace/.hex_home

WORKDIR /workspace

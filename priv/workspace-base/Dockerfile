FROM alpine:3.19

# Install essential tools for workspace operations
RUN apk add --no-cache \
    git \
    github-cli \
    openssh-client \
    bash \
    curl \
    rsync

WORKDIR /workspace

CMD ["sleep", "infinity"]

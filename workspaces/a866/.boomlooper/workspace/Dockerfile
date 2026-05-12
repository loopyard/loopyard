FROM ruby:3.4.2-slim

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
    build-essential git curl libffi-dev libyaml-dev pkg-config \
    libvips imagemagick sqlite3 libsqlite3-dev \
    python-is-python3 node-gyp \
    inotify-tools \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

RUN gem install foreman

RUN set -e; { \
      echo "#!/bin/sh"; \
      echo "set -e"; \
      echo "echo \"==> Initial Tailwind CSS build...\""; \
      echo "bin/rails tailwindcss:build"; \
      echo "echo \"==> Watching for file changes...\""; \
      echo "while inotifywait -r -q -e modify,create,delete,move app/assets/ app/views/ app/helpers/ app/javascript/ 2>/dev/null; do"; \
      echo "  echo \"==> Rebuilding Tailwind CSS...\""; \
      echo "  bin/rails tailwindcss:build || true"; \
      echo "done"; \
    } > /usr/local/bin/tailwind-watch && chmod +x /usr/local/bin/tailwind-watch

WORKDIR /workspace

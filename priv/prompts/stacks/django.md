# Django

## Discovering it's Django

You're looking at a Django project if:
- `manage.py` exists at the repo root
- `settings.py` (or `<project>/settings/base.py`) exists
- `requirements.txt` or `pyproject.toml` lists `Django` (or `django`)
- `INSTALLED_APPS` block in any settings file

For non-Django Python web apps (Flask, FastAPI, Starlette), use `python.md` instead.

## Dockerfile

```dockerfile
FROM python:3.12-slim

RUN apt-get update && apt-get install -y \
    build-essential git curl \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Virtual env OUTSIDE /workspace so the macOS venv from the volume
# doesn't shadow Linux binaries.
ENV VIRTUAL_ENV=/opt/venv
RUN python -m venv $VIRTUAL_ENV
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

WORKDIR /workspace
```

**Check `.python-version` or `pyproject.toml`** — if they require `^3.11` or `^3.10`, switch the base tag (`python:3.11-slim`, `python:3.10-slim`).

**Check `requirements.txt` / `pyproject.toml` for image deps:**
- `psycopg2` (not `psycopg2-binary`) → keep `libpq-dev` (already there)
- `mysqlclient` → add `default-libmysqlclient-dev pkg-config`
- `Pillow` → add `libjpeg-dev zlib1g-dev libfreetype6-dev`
- `cryptography` → add `libssl-dev libffi-dev`
- `lxml` → add `libxml2-dev libxslt-dev`
- `pgvector` (Django wrapper) → make sure the postgres image is `pgvector/pgvector:pg16`, not stock postgres
- `python-magic` → add `libmagic1`
- `weasyprint` → add `libpango-1.0-0 libpangoft2-1.0-0`

**For uv-based projects** (look for `uv.lock` or `pyproject.toml` with `[tool.uv]`):
```dockerfile
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:$PATH"
```
Then use `uv sync` instead of `pip install` in the setup commands below.

## Dev command

In docker-compose.yml:

```yaml
dev:
  build: .
  command: python manage.py runserver 0.0.0.0:8000
  ports:
    - "8000"
  volumes:
    - code:/workspace
  working_dir: /workspace
```

**Always pass `0.0.0.0:8000`** — `python manage.py runserver` defaults to `127.0.0.1:8000` and the eval runner can't reach it from the host. The `0.0.0.0` part is non-negotiable.

If the project has a custom dev launcher (look for `bin/dev`, `scripts/dev.sh`, `Procfile`, or notes in README), prefer that — but verify it binds 0.0.0.0.

For Celery worker projects, the `dev` service is still the web server. Add Celery as a separate service:
```yaml
worker:
  build: .
  command: celery -A myproject worker --loglevel=info
  volumes:
    - code:/workspace
  working_dir: /workspace
  depends_on:
    - redis
```

## Services

In docker-compose.yml:

- **postgres** (most common Django default):
  ```yaml
  postgres:
    image: postgres:16
    environment:
      - POSTGRES_HOST_AUTH_METHOD=trust
      - POSTGRES_DB=app_dev
    volumes:
      - postgres-data:/var/lib/postgresql/data
  ```
- **postgres + pgvector** (if `requirements.txt` or migrations reference pgvector):
  ```yaml
  postgres:
    image: pgvector/pgvector:pg16
    environment:
      - POSTGRES_HOST_AUTH_METHOD=trust
      - POSTGRES_DB=app_dev
  ```
- **redis** (if using `django-redis`, `channels-redis`, Celery, or RQ):
  ```yaml
  redis:
    image: redis:7-alpine
  ```
- **mysql** (rare for Django but possible):
  ```yaml
  mysql:
    image: mysql:8
    environment:
      - MYSQL_ALLOW_EMPTY_PASSWORD=yes
      - MYSQL_DATABASE=app_dev
  ```

## Env vars

```
DATABASE_URL=postgres://postgres@postgres:5432/app_dev
DJANGO_SETTINGS_MODULE=myproject.settings.dev   # only if the project uses split settings
SECRET_KEY=dev-only-not-secret-just-needs-to-be-set
DEBUG=1
ALLOWED_HOSTS=*
REDIS_URL=redis://redis:6379/0
```

**`ALLOWED_HOSTS=*`** is critical — Django rejects requests with a Host header that isn't in `ALLOWED_HOSTS`. The eval runner connects via `localhost:<host_port>` and the Host header will be `localhost:<host_port>`, which Django sees as `localhost`. Without `ALLOWED_HOSTS=*` (or `localhost` in the list) you'll get HTTP 400 with "DisallowedHost".

If the project's `settings.py` reads `ALLOWED_HOSTS` from env, set the env var. If it has a hardcoded list, you may need to write a small `.env.local` or override in compose `environment:`.

**`SECRET_KEY`** — Django won't start without it in `settings.py`. Most projects read it from env via `os.environ['SECRET_KEY']`. Set any non-empty value for dev.

## After docker_compose up

```
exec("pip install -r requirements.txt")    # or: uv sync / pip install -e .
exec("python manage.py migrate")
exec("python manage.py collectstatic --noinput")   # only if STATIC_ROOT is set and the project actually serves static via Django
```

If migrations fail with "relation does not exist" or "no such table" on a fresh DB, the project may need an initial schema dump:
```
exec("python manage.py migrate --run-syncdb")
```

For projects using `django-environ` and a `.env` file:
```
exec("cp .env.example .env")
```
…then edit `.env` to point at the postgres compose service (`DATABASE_URL=postgres://postgres@postgres:5432/...`) instead of `localhost`.

## Gotchas

- **`ALLOWED_HOSTS` rejection.** Symptom: HTTP 400 with `Bad Request (400)` and a "DisallowedHost" log line. Fix: `ALLOWED_HOSTS=*` env var (or `["*"]` in settings).
- **`runserver` defaults to `127.0.0.1`.** Symptom: container is up, agent's `curl http://dev:8000` from inside works, but the runner's host probe gets connection-refused. Fix: always pass `0.0.0.0:8000` to `runserver`.
- **`SECRET_KEY` missing.** Symptom: Django crashes on startup with `ImproperlyConfigured: The SECRET_KEY setting must not be empty`. Fix: set any value for dev.
- **`DEBUG=False` + missing static files.** Symptom: 500 errors, "ValueError: Missing staticfiles manifest entry". Fix: `DEBUG=1` in dev.
- **Migrations vs `--run-syncdb`.** Some projects only have migrations; some mix in models without initial migrations. If `migrate` fails on missing tables, try `--run-syncdb`.
- **Virtual env shadowing.** Always put the venv at `/opt/venv` (outside `/workspace`). A venv inside `/workspace` will pick up macOS binaries from the volume and crash with "Exec format error".
- **Multi-settings projects.** Many big Django apps split settings into `settings/base.py`, `settings/dev.py`, `settings/prod.py`. Set `DJANGO_SETTINGS_MODULE=myproject.settings.dev` (or whatever the dev module is) — without it, Django picks `settings.py` if present, or fails.
- **Channels / ASGI projects** use `daphne` or `uvicorn` instead of `runserver`. Read `asgi.py` and the README. Common: `daphne -b 0.0.0.0 -p 8000 myproject.asgi:application` or `uvicorn myproject.asgi:application --host 0.0.0.0 --port 8000`.

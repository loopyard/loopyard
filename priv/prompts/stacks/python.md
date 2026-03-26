# Python Stack Guide

## Base image

Use `python:3.12-slim`. This is cached locally.

## Dockerfile pattern

```dockerfile
FROM python:3.12-slim

RUN apt-get update && apt-get install -y \
    build-essential git curl \
    && rm -rf /var/lib/apt/lists/*

# Keep venv outside /workspace to avoid clobbering host venv
ENV VIRTUAL_ENV=/opt/venv
RUN python -m venv $VIRTUAL_ENV
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

WORKDIR /workspace
```

Check `requirements.txt` / `pyproject.toml` for extras:
- `psycopg2` → add `libpq-dev`
- `Pillow` → add `libjpeg-dev zlib1g-dev`
- `lxml` → add `libxml2-dev libxslt-dev`

## Dev command

- Django: `python manage.py runserver 0.0.0.0:8000`, port 8000
- Flask: `flask run --host=0.0.0.0`, port 5000
- FastAPI: `uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload`, port 8000

## Services

- **PostgreSQL:** `postgres:16` with `POSTGRES_HOST_AUTH_METHOD=trust`
- **Redis:** `redis:7-alpine`
- **Env vars:** `DATABASE_URL=postgres://postgres@postgres:5432/<app>_dev`

## After rebuild

```
exec: pip install -r requirements.txt    # or: pip install -e .
exec: python manage.py migrate           # Django
exec: alembic upgrade head               # if using Alembic
```

## Common gotchas

- **Virtual env clobbering:** Host macOS venv has wrong binaries. Set `ENV VIRTUAL_ENV=/opt/venv` in Dockerfile.
- **pip install location:** Without the venv redirect, pip installs to `/workspace/.venv` which gets clobbered by the bind mount.
- **.env files:** Django/Flask read `.env` — database URLs may point to localhost. Override via `set_env_vars`.

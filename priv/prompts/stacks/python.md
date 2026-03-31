# Python

## Dockerfile

```dockerfile
FROM python:3.12-slim
RUN apt-get update && apt-get install -y \
    build-essential git curl \
    && rm -rf /var/lib/apt/lists/*
ENV VIRTUAL_ENV=/opt/venv
RUN python -m venv $VIRTUAL_ENV
ENV PATH="$VIRTUAL_ENV/bin:$PATH"
WORKDIR /workspace
```

Check `.python-version` or `pyproject.toml` for version. Add `libpq-dev` if using psycopg2, `libjpeg-dev zlib1g-dev` for Pillow.

## Dev command

- **Django:** `python manage.py runserver 0.0.0.0:8000` on port `8000`
- **Flask:** `flask run --host=0.0.0.0` on port `5000`
- **FastAPI:** `uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload` on port `8000`

## Services

- **postgres:** `postgres:16` with `POSTGRES_HOST_AUTH_METHOD=trust`
- **redis:** `redis:7-alpine` (if using Celery/RQ)

## Env vars

```
DATABASE_URL=postgres://postgres@postgres:5432/<app>_dev
```

## After rebuild

```
exec: pip install -r requirements.txt    # or: pip install -e .
exec: python manage.py migrate           # Django
exec: alembic upgrade head               # if using Alembic
```

## Gotchas

- Virtual env MUST be outside `/workspace` (`/opt/venv`) — otherwise macOS venv from volume is used and binaries crash
- `.env` files may have `localhost` database URLs — override with `set_env_vars`

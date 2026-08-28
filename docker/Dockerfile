# Development image for the CPDE API.
#
# The source is bind-mounted from the host (see docker-compose.yml), so this
# image only needs the dependencies. Editing a file on Windows still triggers
# uvicorn's reloader inside the container.
#
# NOT a production image: it runs --reload, mounts source, and does not use a
# non-root user or a pinned dependency lock. Production would COPY the source
# in, drop --reload, and run as an unprivileged user.
FROM python:3.13-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /srv

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

EXPOSE 8001

# --reload-dir keeps the watcher off site-packages, which is large and never
# changes. Without it the reloader burns CPU scanning dependencies.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8001", \
     "--reload", "--reload-dir", "/srv/app", "--reload-dir", "/srv/static"]

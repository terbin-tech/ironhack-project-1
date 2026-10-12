# Official Python image on the newest stable Python
FROM python:3.15-slim

# curl serves the health check. The package comes from the base image's Debian
# release, which only takes security fixes; exact pins break when the mirror drops a version.
# hadolint ignore=DL3008
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl && \
    rm -rf /var/lib/apt/lists/*

# An unprivileged user for the app; gunicorn needs its home directory.
RUN useradd --create-home --uid 10001 app

WORKDIR /usr/local/app

COPY requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# Redis connection, overridden at runtime
ENV REDIS_HOST=redis
ENV REDIS_PORT=6379

COPY . .

EXPOSE 80

# app (uid 10001). Docker 20.10 and later let an unprivileged user bind port 80 inside a container.
USER 10001

HEALTHCHECK --start-period=10s CMD ["curl", "-fsS", "-o", "/dev/null", "http://localhost/"]

CMD ["gunicorn", "app:app", "-b", "0.0.0.0:80", "--log-file", "-", "--access-logfile", "-", "--workers", "4", "--keep-alive", "0"]

# Node 24, an LTS line
FROM node:24-slim

# curl serves the health check and tini runs as PID 1. The packages come from the
# base image's Debian release, which only takes security fixes; exact pins break
# when the mirror drops a version.
# hadolint ignore=DL3008
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl tini && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /usr/local/app

COPY package*.json ./

RUN npm ci && \
    npm cache clean --force && \
    mv /usr/local/app/node_modules /node_modules

COPY . .

# The database user and password come from the environment (Ansible sets them);
# server.js falls back to postgres/postgres when they are unset.
ENV PORT=80 \
    PG_HOST=db \
    PG_PORT=5432 \
    PG_DATABASE=postgres

EXPOSE 80

# node (uid 1000), the unprivileged user the image ships
USER 1000

HEALTHCHECK --start-period=10s CMD ["curl", "-fsS", "-o", "/dev/null", "http://localhost/"]

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["node", "server.js"]

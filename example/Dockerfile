# ---------------------------------------------------------------------------
# A static Astro site on altoviz/nginx-astro.
#
# The base image is a stock nginx drop-in: root, port 80, official entrypoint.
# This sample deliberately does the opposite — unprivileged uid 101 on port
# 8080, everything writable under /tmp — because that is what Kubernetes and
# OpenShift want, and it shows the base image imposes nothing.
# ---------------------------------------------------------------------------

# Declared before the first FROM so it is in scope for the `serve` stage below —
# an ARG declared between stages is not visible to a FROM line. Override to test
# against a locally built base:
#   docker build --build-arg BASE_IMAGE=nginx-astro:stable -t astro-demo .
ARG BASE_IMAGE=altoviz/nginx-astro:stable

# ------------------------------------------------------------- deps
FROM node:26-slim AS deps
WORKDIR /app
COPY package.json package-lock.json* ./
# npm ci when a lockfile is committed (it should be), npm install otherwise so
# this sample still builds if you copy it without one.
RUN if [ -f package-lock.json ]; then npm ci --no-audit --no-fund; \
    else npm install --no-audit --no-fund; fi

# ------------------------------------------------------------- build
FROM node:26-slim AS build
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
ENV NODE_ENV=production CI=true
# astro-compressor runs last in the integrations list and writes a .br, .zst and
# .gz next to every text asset. Those siblings are the entire point of the base
# image — nothing at request time will ever compress this well.
RUN npm run build

# ------------------------------------------------------------- serve
FROM ${BASE_IMAGE}

COPY nginx.conf            /etc/nginx/nginx.conf
COPY security-headers.conf /etc/nginx/security-headers.conf

# Clear the stock index.html/50x.html first: a COPY only overwrites what it
# brings, so nginx's placeholder error page would otherwise survive in the
# document root of a production image.
RUN rm -rf /usr/share/nginx/html/*
COPY --from=build /app/dist /usr/share/nginx/html

# uid 101 is the base image's own `nginx` user — no need to create or renumber
# anything. /var/cache/nginx must be writable even though this config keeps its
# temp paths in /tmp, because nginx opens the cache dir at startup.
RUN chown -R 101:101 /usr/share/nginx/html /var/cache/nginx \
    && chmod -R a=rX /usr/share/nginx/html

USER 101
EXPOSE 8080

# 127.0.0.1, not localhost: musl resolves localhost to ::1 first while
# `listen 8080` binds IPv4 only, so the probe would get ECONNREFUSED and the
# container would sit permanently unhealthy.
HEALTHCHECK --interval=30s --timeout=3s --start-period=3s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://127.0.0.1:8080/healthz || exit 1

CMD ["nginx", "-g", "daemon off;"]

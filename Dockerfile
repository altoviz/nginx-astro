# syntax=docker/dockerfile:1.11
#
# nginx-astro — stock nginx alpine-slim + Brotli and Zstandard dynamic modules.
#
# There is no official nginx package for either codec: nginx.org/packages/alpine
# ships only acme, geoip, image-filter, njs, otel, perl and xslt. The modules
# therefore have to be compiled here, against the exact nginx version that ends
# up in the runtime stage — a module built for 1.30.4 will not load into 1.31.3.

ARG NGINX_VERSION=1.30.4

# ---------------------------------------------------------------- builder
# Same nginx version, same Alpine release, same toolchain as the runtime stage.
# `nginx:<ver>-alpine` and `nginx:<ver>-alpine-slim` are built from one source,
# so `nginx -V` here reports exactly the arguments the runtime binary was built
# with — which is what makes the resulting .so files loadable.
FROM nginx:${NGINX_VERSION}-alpine AS builder

ARG NGINX_VERSION

# Pinned commits, not branches. ngx_brotli publishes no releases and
# zstd-nginx-module publishes no tags, so a SHA is the only stable reference.
ARG NGX_BROTLI_SHA=a71f9312c2deb28875acc7bacfdd5695a111aa53
ARG ZSTD_MODULE_SHA=057a7d339af1111d04b5a9ac5ae9b0250d17cd94

# The four nginx release-signing keys from https://nginx.org/en/pgp_keys.html.
# Pinned by fingerprint: fetching the key files over the same TLS connection as
# the tarball would only prove nginx.org is self-consistent. If nginx starts
# signing with a fifth key this build fails loudly rather than trusting it.
ARG NGINX_GPG_KEYS="\
13C82A63B603576156E30A4EA0EA981B66B0D967 \
43387825DDB1BB97EC36BA5D007C8D7C15D87369 \
7338973069ED3F443F4D37DFA64FD5B17ADB39A8 \
D6786CE303D9A9022998DC6CC8464D549AF75C0A"

# Deliberately narrow: the stock configure arguments enable no module that needs
# libxml2, libxslt, gd or geoip, so those dev packages are not pulled in.
# zstd-dev is for zstd-nginx-module; brotli is built from ngx_brotli's own
# vendored submodule and needs cmake rather than a system library.
RUN apk add --no-cache \
        build-base \
        cmake \
        curl \
        git \
        gnupg \
        linux-headers \
        openssl-dev \
        pcre2-dev \
        zlib-dev \
        zstd-dev

WORKDIR /usr/src

RUN set -eux; \
    curl -fsSL -o nginx.tar.gz     "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz"; \
    curl -fsSL -o nginx.tar.gz.asc "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz.asc"; \
    GNUPGHOME="$(mktemp -d)"; export GNUPGHOME; \
    for key in arut pluknet sb thresh; do \
        curl -fsSL -o "${GNUPGHOME}/${key}.key" "https://nginx.org/keys/${key}.key"; \
    done; \
    gpg --batch --quiet --import "${GNUPGHOME}"/*.key; \
    # Assert the imported primary fingerprints are *exactly* the pinned set —
    # diff catches both a missing key and an unexpected extra one.
    gpg --batch --with-colons --list-keys \
        | awk -F: '$1 == "pub" { want = 1 } $1 == "fpr" && want { print $10; want = 0 }' \
        | sort > "${GNUPGHOME}/got"; \
    printf '%s\n' ${NGINX_GPG_KEYS} | sort > "${GNUPGHOME}/want"; \
    diff -u "${GNUPGHOME}/want" "${GNUPGHOME}/got"; \
    gpg --batch --verify nginx.tar.gz.asc nginx.tar.gz; \
    gpgconf --kill all || true; \
    rm -rf "${GNUPGHOME}" nginx.tar.gz.asc; \
    mkdir -p nginx; \
    tar -xzf nginx.tar.gz -C nginx --strip-components=1; \
    rm nginx.tar.gz

# Fetch by SHA rather than cloning a branch: `git fetch --depth 1 <sha>` works
# against GitHub and keeps the checkout to a single commit.
RUN set -eux; \
    fetch_at() { \
        mkdir -p "$1"; cd "/usr/src/$1"; \
        git init -q .; \
        git remote add origin "$2"; \
        git fetch -q --depth 1 origin "$3"; \
        git checkout -q FETCH_HEAD; \
        cd /usr/src; \
    }; \
    fetch_at ngx_brotli         https://github.com/google/ngx_brotli.git         "${NGX_BROTLI_SHA}"; \
    fetch_at zstd-nginx-module  https://github.com/tokers/zstd-nginx-module.git  "${ZSTD_MODULE_SHA}"; \
    cd /usr/src/ngx_brotli; \
    git submodule update --init --recursive --depth 1; \
    test -f deps/brotli/CMakeLists.txt

# ngx_brotli's config script links against deps/brotli/out/libbrotli{enc,common}.a
# but does not build them — `make modules` fails at link time with
# "cannot find -lbrotlienc" unless this runs first. Static on purpose: the
# runtime image then needs no brotli package at all.
#
# -O2 rather than the -march=native the upstream README suggests: this image is
# published for every x86-64 and aarch64 machine, not just the builder's.
RUN set -eux; \
    cd /usr/src/ngx_brotli/deps/brotli; \
    cmake -S . -B out \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DBROTLI_DISABLE_TESTS=ON \
        -DCMAKE_C_FLAGS='-O2 -fPIC'; \
    cmake --build out --config Release -j "$(nproc)" \
        --target brotlienc brotlidec brotlicommon; \
    ls -l out/libbrotli*.a

# Replay nginx's own configure arguments verbatim and add the two modules.
# This is the officially documented recipe for third-party dynamic modules and
# is what guarantees a matching NGX_MODULE_SIGNATURE. `eval` is required: the
# argument string contains quoted values with spaces (--with-cc-opt='-Os ...').
# `make modules` builds only the .so files, not the nginx binary.
RUN set -eux; \
    cd /usr/src/nginx; \
    CONFARGS="$(nginx -V 2>&1 | sed -n 's/^configure arguments: //p')"; \
    eval ./configure ${CONFARGS} \
        --add-dynamic-module=/usr/src/ngx_brotli \
        --add-dynamic-module=/usr/src/zstd-nginx-module; \
    make -j"$(nproc)" modules; \
    strip --strip-unneeded objs/*.so; \
    ls -l objs/*.so

# ---------------------------------------------------------------- runtime
# Stock alpine-slim, unmodified except for the modules and one include line.
# Still root, still port 80, still the official entrypoint — a drop-in
# replacement for nginx:alpine-slim.
FROM nginx:${NGINX_VERSION}-alpine-slim

ARG NGINX_VERSION

# zstd-nginx-module links libzstd dynamically. Installed as a package rather
# than copied out of the builder on purpose: a bare .so is invisible to apk, so
# scanners would never report a libzstd CVE against this image and users could
# not `apk upgrade` it. ~600 KB for a tracked, patchable dependency.
# Brotli needs nothing here — it is statically linked into the module.
RUN apk add --no-cache zstd-libs

# /etc/nginx/modules is already a symlink to this path in the official image.
COPY --from=builder \
    /usr/src/nginx/objs/ngx_http_brotli_filter_module.so \
    /usr/src/nginx/objs/ngx_http_brotli_static_module.so \
    /usr/src/nginx/objs/ngx_http_zstd_filter_module.so \
    /usr/src/nginx/objs/ngx_http_zstd_static_module.so \
    /usr/lib/nginx/modules/

COPY modules-enabled/ /etc/nginx/modules-enabled/

# One line prepended to the stock nginx.conf; nothing else about the base
# image's behaviour changes. Anyone replacing /etc/nginx/nginx.conf must carry
# this line over, or nginx exits with `unknown directive "brotli_static"`.
#
# `nginx -t` is a build-time gate: if a module fails to load, the build fails
# rather than the image shipping broken.
RUN set -eux; \
    printf 'include /etc/nginx/modules-enabled/*.conf;\n\n' > /tmp/nginx.conf; \
    cat /etc/nginx/nginx.conf >> /tmp/nginx.conf; \
    mv /tmp/nginx.conf /etc/nginx/nginx.conf; \
    nginx -t

# Populated by docker/metadata-action in CI; harmless defaults for local builds.
ARG IMAGE_CREATED=""
ARG IMAGE_REVISION=""
ARG IMAGE_VERSION="dev"

LABEL org.opencontainers.image.title="nginx-astro" \
      org.opencontainers.image.description="Slim nginx with Brotli and Zstandard dynamic modules, for serving pre-compressed Astro builds" \
      org.opencontainers.image.source="https://github.com/altoviz/nginx-astro" \
      org.opencontainers.image.url="https://github.com/altoviz/nginx-astro" \
      org.opencontainers.image.documentation="https://github.com/altoviz/nginx-astro#readme" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.vendor="Altoviz" \
      org.opencontainers.image.base.name="docker.io/library/nginx:${NGINX_VERSION}-alpine-slim" \
      org.opencontainers.image.created="${IMAGE_CREATED}" \
      org.opencontainers.image.revision="${IMAGE_REVISION}" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      com.altoviz.nginx-astro.nginx-version="${NGINX_VERSION}"

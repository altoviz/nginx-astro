<div align="center">

# nginx-astro

**Stock nginx `alpine-slim`, plus Brotli and Zstandard — so your Astro build ships the bytes it already compressed.**

[![CI](https://github.com/altoviz/nginx-astro/actions/workflows/ci.yml/badge.svg)](https://github.com/altoviz/nginx-astro/actions/workflows/ci.yml)
[![Docker Pulls](https://img.shields.io/docker/pulls/altoviz/nginx-astro?logo=docker&logoColor=white)](https://hub.docker.com/r/altoviz/nginx-astro)
[![Image Size](https://img.shields.io/docker/image-size/altoviz/nginx-astro/latest?logo=docker&logoColor=white&label=image%20size)](https://hub.docker.com/r/altoviz/nginx-astro/tags)
[![nginx](https://img.shields.io/docker/v/altoviz/nginx-astro/stable?logo=nginx&logoColor=white&label=nginx)](https://hub.docker.com/r/altoviz/nginx-astro/tags)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

[Quick start](#quick-start) · [What's inside](#whats-inside) · [Encoding precedence](#encoding-precedence) · [Tags](#tags) · [Full example](#full-example) · [Verifying](#verifying-the-image) · [Getting help](#getting-help) · [Links](#links)

</div>

---

## Why this image exists

Astro can compress your whole site at build time. Add [`astro-compressor`](https://github.com/sondr3/astro-compressor) and every HTML, CSS and JS file gets a `.br`, `.zst` and `.gz` sibling, squeezed at a level no web server would ever spend the CPU on per request.

Then you put it behind `nginx:alpine-slim` and **none of that ships**. Stock nginx has `gzip_static` and nothing else — no brotli, no zstd. Your `.br` files sit in the image, unread, while nginx gzips the original on the fly for every visitor.

There is no official fix. [`nginx.org/packages/alpine`](https://nginx.org/packages/alpine/) ships `acme`, `geoip`, `image-filter`, `njs`, `otel`, `perl` and `xslt` — no brotli, no zstd. The modules have to be compiled against the exact nginx version in the image.

And the usual workarounds get it wrong in a way that is easy to miss: load brotli and zstd carelessly and nginx will hand every modern browser the **zstd** file, which for build-time-compressed text is the *larger* of the two. Compression that makes the page bigger.

This image is stock `nginx:<version>-alpine-slim` with four dynamic modules added, **+2.3 MB**, and the negotiation order settled deliberately in brotli's favour — with a [test](test/smoke.sh) that fails the build if it ever regresses.

```console
$ curl -sI -H 'Accept-Encoding: gzip, deflate, br, zstd' https://your-site/ | grep -i content-encoding
content-encoding: br
```

## Quick start

```dockerfile
FROM altoviz/nginx-astro:stable
COPY dist/ /usr/share/nginx/html
COPY nginx.conf /etc/nginx/nginx.conf
```

Everything else about the base image is stock nginx: root, port 80, the official entrypoint, `/docker-entrypoint.d/` templating, `SIGQUIT` on stop. It is a drop-in replacement for `nginx:alpine-slim`.

> [!IMPORTANT]
> **If you replace `/etc/nginx/nginx.conf`, its first line must be:**
>
> ```nginx
> include /etc/nginx/modules-enabled/*.conf;
> ```
>
> That is where the `load_module` directives live. Without it nginx exits at startup with `unknown directive "brotli_static"`. This image ships no opinionated configuration of its own, so nothing will re-add the line for you.

Then turn the static modules on and leave dynamic compression off — the files are already compressed:

```nginx
brotli_static on;
zstd_static   on;
gzip_static   on;
gzip_vary     on;
```

## What's inside

| | |
|---|---|
| **Base** | [`nginx:<version>-alpine-slim`](https://hub.docker.com/_/nginx) — unmodified |
| **Size** | 23.3 MB vs 21.0 MB stock (**+2.3 MB**) |
| **Platforms** | `linux/amd64`, `linux/arm64` |
| **User / port** | `root` / `80` — identical to stock nginx |
| **Added to `nginx -V`** | two `--add-dynamic-module` flags, nothing else |

### Modules

| Module | Source | Pinned at | Size |
|---|---|---|---|
| `ngx_http_brotli_filter_module` | [google/ngx_brotli](https://github.com/google/ngx_brotli) | [`a71f931`](https://github.com/google/ngx_brotli/commit/a71f9312c2deb28875acc7bacfdd5695a111aa53) | 945 KB |
| `ngx_http_brotli_static_module` | ″ | ″ | 14 KB |
| `ngx_http_zstd_filter_module` | [tokers/zstd-nginx-module](https://github.com/tokers/zstd-nginx-module) | [`057a7d3`](https://github.com/tokers/zstd-nginx-module/commit/057a7d339af1111d04b5a9ac5ae9b0250d17cd94) | 23 KB |
| `ngx_http_zstd_static_module` | ″ | ″ | 14 KB |
| `libzstd` | Alpine `zstd-libs` | tracks the base image | 714 KB |

`gzip_static` needs no module — it is compiled into the stock nginx binary.

Brotli is **statically linked**: its encoder is vendored, built from source and linked into the module, so the runtime image carries no brotli package. libzstd is the opposite — installed with `apk` on purpose, so vulnerability scanners can see it and you can `apk upgrade` it. A `.so` copied out of a builder stage would be invisible to both.

### How it is built

The modules are compiled in a builder stage running the *same nginx version and the same Alpine release* as the runtime stage, replaying nginx's own `configure` arguments verbatim — the officially supported recipe, and what guarantees a matching module signature. The nginx source tarball's PGP signature is checked against the four [nginx release keys](https://nginx.org/en/pgp_keys.html), pinned by fingerprint. The final stage runs `nginx -t`, so a module that fails to load fails the build instead of shipping.

## Encoding precedence

**brotli > zstd > gzip.**

nginx runs body filters in the reverse of their registration order, so the module loaded *last* gets first refusal on a response. This image therefore loads zstd first and brotli second:

```
/etc/nginx/modules-enabled/
├── 10-mod-zstd.conf      loaded first
└── 20-mod-brotli.conf    loaded last → wins
```

Brotli wins because for text compressed once at build time it is simply smaller. From the [example site](example/) in this repo, one HTML page:

| Encoding | Bytes | vs uncompressed |
|---|---|---|
| none | 2,829 | — |
| gzip | 1,449 | −49% |
| zstd | 1,457 | −48% |
| **brotli** | **1,105** | **−61%** |

Every zstd-capable browser also advertises `br`, so preferring brotli costs no compatibility. zstd earns its place as the fallback for clients that send `zstd` without `br`, and for anything you compress at request time, where its speed matters more than its ratio.

**To prefer zstd instead**, swap the load order:

```dockerfile
FROM altoviz/nginx-astro:stable
RUN cd /etc/nginx/modules-enabled \
    && mv 10-mod-zstd.conf 30-mod-zstd.conf
```

## Tags

| Tag | Tracks | Rolling? |
|---|---|---|
| `latest` | newest stable | yes |
| `stable` | newest stable (1.30.x) | yes |
| `mainline` | newest mainline (1.31.x) | yes |
| `1.30` | newest 1.30 patch | yes |
| `1.30.4` | that nginx release, newest rebuild | yes |
| `1.30.4-20260813` | one specific build | **no — immutable** |

Pin `1.30.4-20260813` for reproducible deploys. Use `1.30` to pick up patch releases and rebuilds automatically.

```console
docker pull altoviz/nginx-astro:stable
```

CI rebuilds weekly against the newest nginx patch and the newest Alpine base, so a published tag never quietly rots between commits.

## Full example

[`example/`](example/) is a complete, runnable Astro site: `astro.config.mjs` with `astro-compressor` configured for all three codecs, a production `nginx.conf`, and a Dockerfile that runs the result **unprivileged on port 8080** — showing the base image imposes nothing.

```console
cd example
docker build -t astro-demo .
docker run --rm -p 8080:8080 astro-demo
```

The config covers the things a real Astro deployment needs:

- `/_astro/` — Astro's content-hashed output — cached `immutable` for a year
- HTML never cached, because it is the file that names the hashed assets
- `try_files $uri $uri/index.html $uri.html` — works with `build.format` set to either `directory` or `file`, and with either `trailingSlash` setting
- a real `404` status from Astro's own `404.astro`, via an `internal` location
- `/healthz` for Kubernetes probes and the Docker `HEALTHCHECK`
- security headers, `server_tokens off`, rate and connection limits
- `absolute_redirect off`, so redirects behind a TLS-terminating ingress do not downgrade to `http://`
- everything writable under `/tmp` — it runs with `--read-only`

```console
$ docker run --rm --read-only --tmpfs /tmp -p 8080:8080 astro-demo
$ curl -sI -H 'Accept-Encoding: gzip, deflate, br, zstd' localhost:8080/ | grep -i content-encoding
content-encoding: br
```

## Verifying the image

Images are signed with [cosign](https://github.com/sigstore/cosign) using keyless OIDC — no key to trust, just this repository's workflow identity:

```console
cosign verify altoviz/nginx-astro:stable \
  --certificate-identity-regexp '^https://github\.com/altoviz/nginx-astro/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

Each image also carries an SBOM and max-mode SLSA provenance:

```console
docker buildx imagetools inspect altoviz/nginx-astro:stable --format '{{json .SBOM}}'
docker buildx imagetools inspect altoviz/nginx-astro:stable --format '{{json .Provenance}}'
```

And you can check the behaviour yourself against any build:

```console
./test/smoke.sh altoviz/nginx-astro:stable
```

## Building it yourself

```console
docker build --build-arg NGINX_VERSION=1.30.4 -t nginx-astro:stable .
./test/smoke.sh nginx-astro:stable
```

`NGINX_VERSION`, `NGX_BROTLI_SHA` and `ZSTD_MODULE_SHA` are all build args — bumping a module is a one-line change.

## Getting help

| | |
|---|---|
| 🐛 **Something broken, or an idea?** | [Open an issue](https://github.com/altoviz/nginx-astro/issues/new) — bugs, feature requests and questions all welcome |
| 🔎 **Check first** | [Existing issues](https://github.com/altoviz/nginx-astro/issues?q=is%3Aissue) — open and closed |
| 🔒 **Security vulnerability** | [Report it privately](https://github.com/altoviz/nginx-astro/security/advisories/new) — please don't open a public issue |

### Filing an issue that gets fixed quickly

Most reports about this image come down to one of three things, and all three are quick to
diagnose if you paste the following:

```console
# 1. Exactly which image — the tag alone is not enough, most are rolling
docker image inspect <image> --format '{{index .RepoDigests 0}}{{"\n"}}{{.Os}}/{{.Architecture}}'

# 2. What nginx thinks it is running
docker run --rm <image> nginx -V 2>&1 | head -1

# 3. Whether the modules load at all
docker run --rm <image> nginx -t
```

Plus your `nginx.conf` — or at minimum **its first line**. If nginx exits with
`unknown directive "brotli_static"`, that is the whole answer: the config is missing
`include /etc/nginx/modules-enabled/*.conf;`. See [Quick start](#quick-start).

If the problem is *which* encoding gets served, run the test suite and paste its output — it
checks the negotiation for every combination and says which one disagreed:

```console
./test/smoke.sh <image>
```

## Links

| | |
|---|---|
| 📦 **Source code** | [github.com/altoviz/nginx-astro](https://github.com/altoviz/nginx-astro) |
| 🐳 **Docker Hub** | [altoviz/nginx-astro](https://hub.docker.com/r/altoviz/nginx-astro) |
| ⚙️ **Build pipeline** | [Actions](https://github.com/altoviz/nginx-astro/actions/workflows/ci.yml) — every image is built and tested here |
| 🌍 **Altoviz** | [altoviz.com](https://altoviz.com) — invoicing and accounting for small French businesses |
| 📖 **Altoviz docs** | [docs.altoviz.com](https://docs.altoviz.com) |
| 🧑‍💻 **Altoviz Developer Hub** | [developer.altoviz.com](https://developer.altoviz.com) — API reference and guides |

### Upstream projects

This image is a small amount of glue around other people's work. If your problem is with
compression behaviour itself rather than with how this image packages it, these are the right
places to look:

- [nginx](https://nginx.org) — the server, and its [security advisories](https://nginx.org/en/security_advisories.html)
- [google/ngx_brotli](https://github.com/google/ngx_brotli) — the Brotli modules
- [tokers/zstd-nginx-module](https://github.com/tokers/zstd-nginx-module) — the Zstandard modules
- [sondr3/astro-compressor](https://github.com/sondr3/astro-compressor) — what writes the `.br`/`.zst`/`.gz` files this image serves

## Licence

MIT — see [LICENSE](LICENSE). The bundled components keep their own licences: [nginx](https://nginx.org/LICENSE) (BSD-2-Clause), [ngx_brotli](https://github.com/google/ngx_brotli/blob/master/LICENSE) (BSD-2-Clause), [zstd-nginx-module](https://github.com/tokers/zstd-nginx-module/blob/master/LICENSE) (BSD-2-Clause), [zstd](https://github.com/facebook/zstd/blob/dev/LICENSE) (BSD-3-Clause / GPL-2.0).

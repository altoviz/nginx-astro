# CLAUDE.md

Guidance for Claude Code working in this repo. The [README](README.md) explains what the
image is for users; this file records what will bite you as a maintainer.

## What this repo is

A published base image: stock `nginx:<version>-alpine-slim` plus four dynamic modules
(brotli filter/static, zstd filter/static). No application code. Two nginx lines are built
from one `Dockerfile` — stable and mainline — for `linux/amd64` and `linux/arm64`.

Published to `docker.io/altoviz/nginx-astro` and mirrored to `ghcr.io/altoviz/nginx-astro`.

**The GHCR mirror is private and undocumented on purpose.** CI still publishes it, but the
README does not mention it, because an anonymous `docker pull ghcr.io/...` is denied and the
package page 404s. Do not "fix" the README by adding GHCR back — make the package public first
(see [CI notes](#ci-notes)), then re-add the pull command under Tags and a row under Links.

## The one thing that must never regress

**Brotli must win over zstd** when a browser sends `Accept-Encoding: gzip, deflate, br, zstd`.
That is the entire reason this image exists — the naive builds get it backwards and serve the
*larger* file to every visitor.

nginx runs body filters in the **reverse** of their registration order, so the module loaded
**last** wins. `modules-enabled/` is numbered accordingly:

```
10-mod-zstd.conf     loaded first
20-mod-brotli.conf   loaded last  → wins
```

Renaming those files silently flips the preference. `test/smoke.sh` asserts the outcome
behaviourally — run it after touching anything in `modules-enabled/` or the `Dockerfile`.

## Always run the smoke test

```bash
docker build --build-arg NGINX_VERSION=1.30.4 -t nginx-astro:stable .
./test/smoke.sh nginx-astro:stable
```

It is not a "does it start" check: it serves fixtures whose `.br`/`.zst`/`.gz` variants have
deliberately different sizes and asserts which one comes back, plus that decompressed bodies
round-trip byte-identically. It needs a working Docker daemon and pulls `alpine:3.24` to do
the compressing and decoding, so the host needs no brotli/zstd CLI.

CI runs it on all four line × arch combinations before anything is pushed.

## Traps already hit (do not rediscover these)

**`ngx_brotli` does not build its own vendored brotli.** Its `config` script links against
`deps/brotli/out/libbrotli{enc,common}.a` but never creates them, so `make modules` dies with
`cannot find -lbrotlienc`. The `Dockerfile` cmake-builds them in a separate step first. Keep
`-O2 -fPIC` there — the upstream README suggests `-march=native`, which would produce an image
that crashes on any CPU older than the builder's.

**`eval` is required when replaying nginx's configure arguments.** `nginx -V` emits
`--with-cc-opt='-Os -fomit-frame-pointer -g'` — quoted values containing spaces. Without
`eval` the shell word-splits them and configure fails.

**Multi-registry push by digest breaks with attestations.** Two `type=image` outputs in one
`build-push-action` step do *not* work: SLSA provenance embeds the target image reference, so
docker.io and ghcr.io get different attestation manifests, hence different wrapping indexes —
and only the last export's digest is reported. The merge job then asks Docker Hub for a digest
that exists only on GHCR (`ERROR: ...@sha256:...: not found`). Push by digest to **Docker Hub
only**, then copy the finished manifest lists to GHCR. Read each registry's digest back before
signing rather than assuming a cross-registry copy is byte-identical.

**The Docker Hub tag API returns 404, not an empty page**, past the end of a filtered result
set. `curl -f` plus `pipefail` turns that into a failed job. Paginate by following `.next`.

**`expires` and `add_header Cache-Control` both emit a Cache-Control header.** Using them
together sends it twice with conflicting values. Use `add_header` alone — `Cache-Control`
supersedes the legacy `Expires` for any cache written this century.

**`ARG` used in a `FROM` must be declared before the first `FROM`.** An ARG declared between
stages is not in scope for a later `FROM` line (see `example/Dockerfile`).

## Deliberate choices — don't "simplify" these

- **libzstd comes from `apk`, brotli is statically linked.** Copying `libzstd.so.1` out of the
  builder would be smaller but invisible to Trivy/Scout and impossible to `apk upgrade`.
  Brotli is vendored and static because there is no equivalent Alpine runtime package worth
  depending on.
- **The base ships no opinionated nginx.conf.** Only one line is added to the stock config:
  `include /etc/nginx/modules-enabled/*.conf;`. The Astro-tuned config lives in `example/`.
- **No entrypoint script re-adds that include.** The official entrypoint skips
  `/docker-entrypoint.d/` entirely when not running as root, so such a script would work in the
  base image and silently not work in any non-root consumer. The failure mode without it is
  loud (`unknown directive "brotli_static"` at startup), which is better than half-working.
- **The base stays root on port 80** — a true drop-in for `nginx:alpine-slim`. The non-root,
  port-8080 treatment belongs in consumers; `example/` demonstrates it.
- **No GitVersion.** Image tags derive from the nginx version discovered at run time plus a
  build date, not from this repo's git history. See below.

## Versioning

There is no `GitVersion.yml` and no SemVer of our own. The `resolve` job queries Docker Hub for
the newest `X.Y.Z-alpine-slim` tag on each line (even minor = stable, odd = mainline) and the
`merge` job derives every tag from that plus `date -u +%Y%m%d`:

| Line | Tags |
|---|---|
| stable | `1.30.4`, `1.30`, `stable`, `latest`, `1.30.4-20260813` |
| mainline | `1.31.3`, `1.31`, `mainline`, `1.31.3-20260813` |

Only the dated tags are immutable; everything else is rebuilt weekly by cron against the newest
nginx patch and Alpine base. Traceability to source is via labels
(`org.opencontainers.image.revision`), not tags.

**Consequence:** the weekly rebuild republishes `stable`/`latest` with zero commits. Nothing to
bump, nothing to merge. Don't add a version file "for consistency" — it would have nothing to
compute on a cron-triggered run.

## Module updates

`NGX_BROTLI_SHA` and `ZSTD_MODULE_SHA` are pinned commit SHAs (neither upstream publishes
usable release tags). Bumping is a one-line `ARG` change plus a smoke-test run. Update the
commit links in the README's module table at the same time.

## CI notes

- Builds run on **native runners** (`ubuntu-24.04` and `ubuntu-24.04-arm`), never QEMU —
  compiling brotli under emulation is roughly 10× slower.
- Required secrets: `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`. GHCR uses the built-in token.
- GHCR **package visibility is UI-only** — there is no REST endpoint, so this cannot be scripted.
  The package is currently **private**; to publish it, flip visibility at
  `https://github.com/orgs/altoviz/packages/container/nginx-astro/settings` and only then
  document GHCR in the README.
- Signing is keyless cosign via OIDC; the identity is
  `https://github.com/altoviz/nginx-astro/.github/workflows/ci.yml@refs/heads/main`.

## Protocols

HTTP/2 and HTTP/3 both work — inherited from the stock base (`--with-http_v2_module`,
`--with-http_v3_module`) and a runtime linked against OpenSSL 3.5, which has the native QUIC
server API. Verified: h2 over TLS, h2c cleartext, and h3 over QUIC all negotiate, and
`brotli_static` serves correctly over h3. Neither is enabled by default — the image ships no
config and both need TLS the consumer supplies. HTTP/3 also needs UDP published.

## Downstream consumers

Altoviz Astro sites already on this base — check them before making a breaking change:

| Repo | Pin |
|---|---|
| `altoviz/devhub` | `ARG NGINX_IMAGE=altoviz/nginx-astro:1.31.3-20260813` (CI overrides with an ACR mirror) |
| `altoviz/docs` | `FROM altoviz/nginx-astro:1.31.3` |

Both carry `include /etc/nginx/modules-enabled/*.conf;` as line 1 of their `nginx.conf`. If
that mechanism ever changes, those repos break at container start, not at build.

## Conventions

Comments explain *why*, not *what* — especially where the code looks odd (module numbering,
`eval`, the single-registry push). That style is consistent across the Altoviz repos; match it.

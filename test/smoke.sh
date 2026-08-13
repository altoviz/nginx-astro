#!/usr/bin/env sh
# Behavioural smoke test for a built nginx-astro image.
#
#   ./test/smoke.sh [image]        (default: nginx-astro:stable)
#
# This is not a "does it start" check. The reason this image exists is that the
# obvious ways of adding brotli and zstd to nginx get the *negotiation* wrong and
# quietly serve the larger payload to every visitor. So the test serves a fixture
# whose three pre-compressed variants have deliberately different sizes and
# asserts, byte for byte, which one comes back.

set -eu

IMAGE="${1:-nginx-astro:stable}"
CONTAINER="nginx-astro-smoke-$$"
WORKDIR="$(mktemp -d)"
PORT=""
FAILED=0

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    rm -rf "$WORKDIR"
}
trap cleanup EXIT INT TERM

pass() { printf '  \033[32mok\033[0m    %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILED=$((FAILED + 1)); }
info() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# assert_encoding <accept-encoding header value or empty> <expected content-encoding or "none">
assert_encoding() {
    ae="$1"; expected="$2"
    if [ -z "$ae" ]; then
        # curl always sends Accept-Encoding unless told otherwise; an empty
        # header value is how you actually suppress it.
        hdrs="$(curl -sS -D - -o /dev/null -H 'Accept-Encoding;' "http://127.0.0.1:${PORT}/index.html")"
        label='no Accept-Encoding'
    else
        hdrs="$(curl -sS -D - -o /dev/null -H "Accept-Encoding: ${ae}" "http://127.0.0.1:${PORT}/index.html")"
        label="Accept-Encoding: ${ae}"
    fi

    got="$(printf '%s' "$hdrs" | tr -d '\r' | sed -n 's/^[Cc]ontent-[Ee]ncoding: //p')"
    [ -n "$got" ] || got=none

    if [ "$got" = "$expected" ]; then
        pass "${label} -> ${got}"
    else
        fail "${label} -> expected '${expected}', got '${got}'"
    fi

    # Any content-negotiated response must be cacheable correctly by proxies.
    if printf '%s' "$hdrs" | tr -d '\r' | grep -qi '^vary:.*accept-encoding'; then
        pass "${label} -> Vary: Accept-Encoding present"
    else
        fail "${label} -> Vary: Accept-Encoding missing"
    fi
}

info "Image: ${IMAGE}"
docker image inspect "$IMAGE" >/dev/null

# ---------------------------------------------------------------- 1. config
info "1. Configuration and modules"

if docker run --rm "$IMAGE" nginx -t >/dev/null 2>&1; then
    pass "nginx -t succeeds with modules-enabled/*.conf loaded"
else
    fail "nginx -t failed"
    docker run --rm "$IMAGE" nginx -t || true
fi

for mod in ngx_http_brotli_filter_module ngx_http_brotli_static_module \
           ngx_http_zstd_filter_module ngx_http_zstd_static_module; do
    if docker run --rm "$IMAGE" test -f "/usr/lib/nginx/modules/${mod}.so"; then
        pass "${mod}.so present"
    else
        fail "${mod}.so missing"
    fi
done

# Brotli is vendored and statically linked; a libbrotli* dependency here would
# mean the runtime image is one apk away from failing to start.
brotli_libs="$(docker run --rm "$IMAGE" sh -c \
    'ldd /usr/lib/nginx/modules/ngx_http_brotli_filter_module.so 2>&1' || true)"
if printf '%s' "$brotli_libs" | grep -qi 'libbrotli'; then
    fail "brotli module links libbrotli dynamically (expected static)"
    printf '%s\n' "$brotli_libs"
else
    pass "brotli module has no libbrotli runtime dependency"
fi

# zstd is the opposite: linked against the apk-tracked zstd-libs so scanners can
# see it and users can upgrade it. It must actually resolve.
zstd_libs="$(docker run --rm "$IMAGE" sh -c \
    'ldd /usr/lib/nginx/modules/ngx_http_zstd_filter_module.so 2>&1' || true)"
if printf '%s' "$zstd_libs" | grep -qi 'libzstd.*not found'; then
    fail "zstd module cannot resolve libzstd"
    printf '%s\n' "$zstd_libs"
elif printf '%s' "$zstd_libs" | grep -qi 'libzstd'; then
    pass "zstd module resolves libzstd from the zstd-libs package"
else
    fail "zstd module does not link libzstd at all"
    printf '%s\n' "$zstd_libs"
fi

# ---------------------------------------------------------------- 2. fixture
info "2. Serving pre-compressed fixtures"

# Compressible enough that all three codecs produce distinctly different sizes.
mkdir -p "$WORKDIR/html"
i=0
while [ "$i" -lt 400 ]; do
    printf '<p class="astro-fixture">line %s: the quick brown fox jumps over the lazy dog</p>\n' "$i"
    i=$((i + 1))
done > "$WORKDIR/html/index.html"

# Compress inside a throwaway container so the host needs no brotli/zstd CLI.
docker run --rm -v "$WORKDIR/html:/html" alpine:3.24 sh -c '
    set -e
    apk add --no-cache brotli zstd gzip >/dev/null
    brotli -q 11 -k /html/index.html
    zstd -19 -q -k /html/index.html -o /html/index.html.zst
    gzip -9 -k /html/index.html
    chmod 0644 /html/index.html.*
' >/dev/null

for f in br zst gz; do
    [ -s "$WORKDIR/html/index.html.$f" ] || { fail "fixture index.html.$f was not created"; exit 1; }
done
pass "fixtures: $(cd "$WORKDIR/html" && ls -1 index.html* | tr '\n' ' ')"

cat > "$WORKDIR/nginx.conf" <<'CONF'
# Line 1 is the line every consumer of this image has to copy.
include /etc/nginx/modules-enabled/*.conf;

events { worker_connections 128; }

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    access_log    off;

    # Pre-compressed only. Dynamic compression stays off so the test measures
    # which *_static module wins, not which filter recompresses fastest.
    brotli_static on;
    zstd_static   on;
    gzip_static   on;
    gzip_vary     on;

    server {
        listen 80;
        root   /usr/share/nginx/html;
        index  index.html;
    }
}
CONF

docker run -d --name "$CONTAINER" -P \
    -v "$WORKDIR/nginx.conf:/etc/nginx/nginx.conf:ro" \
    -v "$WORKDIR/html:/usr/share/nginx/html:ro" \
    "$IMAGE" >/dev/null

PORT="$(docker port "$CONTAINER" 80/tcp | head -n1 | sed 's/.*://')"

ready=0
i=0
while [ "$i" -lt 50 ]; do
    if curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/index.html" 2>/dev/null; then ready=1; break; fi
    i=$((i + 1))
    sleep 0.2
done
if [ "$ready" -ne 1 ]; then
    fail "container did not become ready"
    docker logs "$CONTAINER" || true
    exit 1
fi
pass "container serving on :80 as $(docker exec "$CONTAINER" id -un) (stock drop-in)"

# ---------------------------------------------------------------- 3. negotiation
info "3. Encoding negotiation (brotli > zstd > gzip)"

# The one that matters: a modern browser sends all four and must get brotli.
assert_encoding 'gzip, deflate, br, zstd' 'br'
assert_encoding 'br, zstd'                'br'
assert_encoding 'gzip, zstd'              'zstd'
assert_encoding 'gzip, deflate'           'gzip'
assert_encoding ''                        'none'

# Decompressed bodies must match the original — a wrong Content-Encoding header
# on a correct body (or vice versa) is worse than no compression at all.
orig_sum="$(sha256sum < "$WORKDIR/html/index.html" | cut -d' ' -f1)"
for ae in 'gzip, deflate, br, zstd' 'gzip, zstd' 'gzip, deflate'; do
    # Decode in a container rather than with the host curl: `curl --compressed`
    # only handles the codecs it was linked against, and almost no distro curl
    # can decode zstd. This way the assertion holds on any host.
    got_sum="$(docker run --rm --network host alpine:3.24 sh -c "
        apk add --no-cache curl brotli zstd >/dev/null
        curl -sS -H 'Accept-Encoding: ${ae}' -o /tmp/body -D /tmp/hdr http://127.0.0.1:${PORT}/index.html
        enc=\$(tr -d '\r' < /tmp/hdr | sed -n 's/^[Cc]ontent-[Ee]ncoding: //p')
        case \"\$enc\" in
            br)   brotli -d -c /tmp/body ;;
            zstd) zstd -d -c -q /tmp/body ;;
            gzip) gzip -d -c /tmp/body ;;
            *)    cat /tmp/body ;;
        esac | sha256sum | cut -d' ' -f1
    " 2>/dev/null | tr -d '[:space:]')"

    if [ "$got_sum" = "$orig_sum" ]; then
        pass "body round-trips intact for '${ae}'"
    else
        fail "body mismatch for '${ae}' (${got_sum:-empty} != ${orig_sum})"
    fi
done

# ---------------------------------------------------------------- 4. summary
info "Summary"
if [ "$FAILED" -eq 0 ]; then
    printf '  \033[32mall checks passed\033[0m for %s\n\n' "$IMAGE"
    exit 0
fi
printf '  \033[31m%s check(s) failed\033[0m for %s\n\n' "$FAILED" "$IMAGE"
exit 1

// @ts-check
import { defineConfig } from "astro/config";
import compressor from "astro-compressor";

export default defineConfig({
  site: "https://example.com",

  build: {
    // The default. Emits /about/index.html rather than /about.html; the
    // try_files chain in nginx.conf handles either, so switch freely.
    format: "directory",
    // Astro's content-hashed output directory. nginx.conf caches this path
    // immutably for a year — if you rename it here, rename it there too.
    assets: "_astro",
    // Default is 'auto', which inlines stylesheets under ~4 kB. This sample is
    // small enough that everything would be inlined and dist/_astro/ would not
    // exist at all — leaving the immutable-caching rule in nginx.conf
    // undemonstrated. Real sites should keep the default.
    inlineStylesheets: "never",
  },

  integrations: [
    // MUST be last. astro-compressor walks dist/ after every other integration
    // has finished writing to it; anything that emits files later ships
    // uncompressed and silently falls back to an identity response.
    compressor({
      gzip: true,
      brotli: true,
      zstd: true,

      // Defaults to [.css, .js, .html, .xml, .cjs, .mjs, .svg, .txt] — widened
      // for the JSON and manifest files a real site also serves. Binary formats
      // (png, webp, avif, woff2) are left out on purpose: they are already
      // compressed, and a .br sibling would be larger than the original.
      fileExtensions: [
        ".css",
        ".js",
        ".cjs",
        ".mjs",
        ".html",
        ".xml",
        ".svg",
        ".txt",
        ".json",
        ".webmanifest",
        ".md",
      ],
    }),
  ],
});

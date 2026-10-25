#!/bin/sh
# Cloudflare Pages build: copy ONLY the site into dist/ so that supabase/,
# ml-service/ and editor files are never published, then minify CSS and JS.
#   Build command:          sh build.sh   (the file in the repository root calls this one)
#   Build output directory: dist
set -eu

# Always work from the repository root, wherever the script is started from.
cd "$(dirname "$0")/.."

rm -rf dist
mkdir dist
cp -R index.html admin student teacher assets styles dist/
cp config/robots.txt config/_headers dist/
find dist -name '.DS_Store' -delete

# A top-level 404.html makes Cloudflare Pages answer unknown URLs with a real
# 404 instead of the landing page (status 200). The source page uses relative
# paths for the folder it lives in, so rewrite them to absolute ones.
sed -e 's#"\.\./\.\./styles/#"/styles/#g' \
    -e 's#"\.\./js/#"/assets/js/#g' \
    -e 's#"\.\./\.\./index\.html"#"/"#g' \
    assets/html/404.html > dist/404.html

# Minify. Whitespace and syntax only: names are kept, because the scripts share
# globals. If esbuild cannot run, the unminified copy is published as is.
ESBUILD="${ESBUILD:-npx --yes esbuild@0.24.0}"
FILES=$(find dist/styles dist/admin dist/student dist/teacher dist/assets/js -type f \( -name '*.css' -o -name '*.js' \) ! -path '*/vendor/*')
if $ESBUILD $FILES --minify-whitespace --minify-syntax --target=es2020,chrome90,safari14,firefox90 \
    --outbase=dist --outdir=dist --allow-overwrite --log-level=error; then
    echo "minified $(echo "$FILES" | wc -w) files"
else
    echo "minify skipped: publishing unminified files"
fi

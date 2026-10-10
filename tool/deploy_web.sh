#!/usr/bin/env bash
# Builds the web app and publishes it to GitHub Pages:
#   https://rodrigomedeirosbrazil.github.io/fly-app/
#
# Pages serves the `gh-pages` branch, which holds only the build output. This
# replaces its contents with a fresh build and pushes one commit. Run it from
# a clean checkout of the commit you mean to publish: the commit message
# records which one it was.
set -euo pipefail

cd "$(dirname "$0")/.."
root=$(pwd)

./tool/build_web.sh

source_commit=$(git rev-parse --short HEAD)
if ! git diff --quiet HEAD; then
  source_commit="$source_commit-dirty"
fi

pages=$(mktemp -d)
trap 'git -C "$root" worktree remove --force "$pages" 2>/dev/null || true; rm -rf "$pages"' EXIT

git fetch -q origin gh-pages
git worktree add -q "$pages" origin/gh-pages --detach

# Replace everything but the .git link: files the new build no longer has
# must not linger on the site.
find "$pages" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
cp -R build/web/. "$pages/"
# Debug symbols are megabytes nobody loads; .nojekyll keeps Pages from
# running the files through Jekyll.
find "$pages" -name '*.symbols' -delete
rm -f "$pages/.last_build_id"
touch "$pages/.nojekyll"

cd "$pages"
git add -A
if git diff --cached --quiet; then
  echo "Nothing changed; the site already serves this build."
  exit 0
fi
git commit -q -m "deploy: web build from $source_commit"
git push -q origin HEAD:gh-pages
echo "Published $source_commit. Pages takes a minute or two to serve it."

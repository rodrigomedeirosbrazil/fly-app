#!/usr/bin/env bash
# Regenerates the app screenshots used by the user manual and copies them
# into the fly-controller repo, where the manual lives (docs/manual/img).
#
#   tool/manual_screens.sh [path/to/fly-controller]
#
# Defaults to a fly-controller checkout next to this repo. Review the images
# and commit them there; nothing is committed here.
set -euo pipefail

cd "$(dirname "$0")/.."
dest="${1:-../fly-controller}/docs/manual/img"
if [ ! -d "$dest" ]; then
  echo "No manual at $dest — pass the fly-controller checkout as the first argument." >&2
  exit 1
fi

# The fonts are read from the Flutter SDK (see loadFonts in the test).
export FLUTTER_ROOT="$(dirname "$(dirname "$(readlink -f "$(command -v flutter)")")")"

flutter test tool/manual_screens --update-goldens
cp tool/manual_screens/shots/*.png "$dest/"
echo "Copied $(ls tool/manual_screens/shots/*.png | wc -l | tr -d ' ') images to $dest"

#!/bin/bash
# Tests against a BUILT image: what the unit tests cannot see, because they run the scripts with
# the machine's own Python and tools, not the image's.
#
#   ./tests/test-image.sh [image]        default 7dtd-server-flux:local
#
# The first published image passed every unit test and could not unpack a mod: it installed
# python3-minimal, which has no shutil, zipfile or tarfile, so flux-unpack.py died on its imports
# and MODS_URLS never installed anything. CI runs this BEFORE it publishes.
#
# No Steam and no game: tests/image/in-container.sh puts a stand-in steamcmd and a stand-in server
# in the container and runs the real supervisor around them.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

image="${1:-7dtd-server-flux:local}"
docker run --rm --entrypoint bash -v "${PWD}/tests:/t:ro" "${image}" /t/image/in-container.sh

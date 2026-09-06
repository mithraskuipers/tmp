#!/usr/bin/env bash
set -e

REPO="mithraskuipers/tmp"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZIP_PATH="$DIR/tmp-repo.zip"

BRANCH=$(curl -fsSL "https://api.github.com/repos/$REPO" | grep '"default_branch"' | sed -E 's/.*"default_branch": *"([^"]+)".*/\1/')

curl -fL "https://github.com/$REPO/archive/refs/heads/$BRANCH.zip" -o "$ZIP_PATH"
unzip -o "$ZIP_PATH" -d "$DIR"
rm "$ZIP_PATH"

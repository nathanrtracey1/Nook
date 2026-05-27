#!/usr/bin/env bash
set -euo pipefail

echo "Fetching upstream..."
git fetch upstream

echo "Updating main from upstream/main..."
git checkout main
git merge upstream/main

echo "Rebasing custom-dev onto main..."
git checkout custom-dev
git rebase main

echo "Done. Your custom-dev branch is now rebased on the latest upstream main."


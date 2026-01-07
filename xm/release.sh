#!/bin/bash
set -e

# xm Release Script
# Creates a new version tag and pushes to trigger the release pipeline

# Get the latest tag
latest_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")

# Parse version components
version=${latest_tag#v}
IFS='.' read -r major minor patch <<< "$version"

# Increment based on argument (default: patch)
case "${1:-patch}" in
  major)
    major=$((major + 1))
    minor=0
    patch=0
    ;;
  minor)
    minor=$((minor + 1))
    patch=0
    ;;
  patch)
    patch=$((patch + 1))
    ;;
  *)
    echo "Usage: $0 [major|minor|patch]"
    echo ""
    echo "Examples:"
    echo "  $0           # Bump patch version (0.1.0 -> 0.1.1)"
    echo "  $0 patch     # Bump patch version (0.1.0 -> 0.1.1)"
    echo "  $0 minor     # Bump minor version (0.1.0 -> 0.2.0)"
    echo "  $0 major     # Bump major version (0.1.0 -> 1.0.0)"
    exit 1
    ;;
esac

new_tag="v${major}.${minor}.${patch}"

echo "Current tag: $latest_tag"
echo "New tag: $new_tag"
echo ""

# Confirm
read -p "Create and push tag $new_tag? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 1
fi

git tag -a "$new_tag" -m "Release $new_tag"

# Push to origin (Codeberg - triggers Woodpecker for Linux builds)
echo "Pushing to origin..."
git push origin "$new_tag"

# Push to GitHub mirror (triggers GitHub Actions for macOS builds)
if git remote | grep -q '^github$'; then
  echo "Pushing to github..."
  git push github "$new_tag"
else
  echo "Note: 'github' remote not configured. macOS builds skipped."
  echo "Add with: git remote add github git@github.com:anuna-research/xm.git"
fi

echo ""
echo "Released $new_tag"
echo ""
echo "CI pipelines triggered:"
echo "  - Woodpecker (Linux): Check your Woodpecker instance"
echo "  - GitHub Actions (macOS): https://github.com/anuna-research/xm/actions"
echo ""
echo "Once complete, the release will be available at:"
echo "  https://files.anuna.io/xm/$new_tag/"
echo "  https://files.anuna.io/xm/latest/"

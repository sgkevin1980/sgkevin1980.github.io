#!/bin/bash
# publish.sh - Convert a markdown file to a Jekyll post and publish
#
# Usage:
#   ./publish.sh <markdown-file> [date]
#
# Examples:
#   ./publish.sh ~/Documents/my-article.md
#   ./publish.sh ~/Documents/my-article.md 2026-03-20
#
# What it does:
#   1. Extracts the title from the first # heading
#   2. Generates a slug from the title
#   3. Adds Jekyll front matter
#   4. Copies to _posts/ with correct naming
#   5. Adds a link to index.md
#   6. Commits and pushes to GitHub
#   7. Site rebuilds automatically (~1-2 min)

set -e

# --- Validate input ---
if [ -z "$1" ]; then
  echo "Usage: ./publish.sh <markdown-file> [date]"
  echo ""
  echo "Examples:"
  echo "  ./publish.sh ~/Documents/my-article.md"
  echo "  ./publish.sh ~/Documents/my-article.md 2026-03-20"
  exit 1
fi

SOURCE_FILE="$1"
if [ ! -f "$SOURCE_FILE" ]; then
  echo "Error: File not found: $SOURCE_FILE"
  exit 1
fi

# --- Extract title and date ---
TITLE=$(grep -m1 '^# ' "$SOURCE_FILE" | sed 's/^# //')
if [ -z "$TITLE" ]; then
  echo "Error: No # heading found in $SOURCE_FILE"
  echo "The first line starting with '# ' is used as the title."
  exit 1
fi

POST_DATE="${2:-$(date +%Y-%m-%d)}"

# Generate slug: lowercase, replace spaces/special chars with dashes
SLUG=$(echo "$TITLE" \
  | tr '[:upper:]' '[:lower:]' \
  | sed 's/[^a-z0-9 ]//g' \
  | sed 's/  */ /g' \
  | sed 's/ /-/g' \
  | sed 's/--*/-/g' \
  | sed 's/^-//;s/-$//')

POST_FILE="_posts/${POST_DATE}-${SLUG}.md"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

cd "$REPO_DIR"

# --- Check if post already exists ---
if [ -f "$POST_FILE" ]; then
  echo "Post already exists: $POST_FILE"
  read -p "Overwrite? (y/N): " CONFIRM
  if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    echo "Aborted."
    exit 0
  fi
fi

# --- Build the post ---
echo "---"                              >  "$POST_FILE"
echo "layout: default"                  >> "$POST_FILE"
echo "title: \"$TITLE\""               >> "$POST_FILE"
echo "date: $POST_DATE"                 >> "$POST_FILE"
echo "---"                              >> "$POST_FILE"
echo ""                                 >> "$POST_FILE"
cat "$SOURCE_FILE"                      >> "$POST_FILE"

echo "Created: $POST_FILE"

# --- Update index.md ---
LINK_LINE="- [$TITLE]({% link $POST_FILE %})"
MONTH_YEAR=$(date -j -f "%Y-%m-%d" "$POST_DATE" "+%B %Y" 2>/dev/null \
  || date -d "$POST_DATE" "+%B %Y" 2>/dev/null \
  || echo "$POST_DATE")
FULL_LINK="- [$TITLE]({% link $POST_FILE %}) — $MONTH_YEAR"

if grep -qF "$POST_FILE" index.md 2>/dev/null; then
  echo "Link already in index.md, skipping."
else
  # Insert after the ## Articles heading
  if grep -q "^## Articles" index.md; then
    sed -i '' "/^## Articles/a\\
\\
$FULL_LINK" index.md 2>/dev/null || \
    sed -i "/^## Articles/a\\$FULL_LINK" index.md
    echo "Added link to index.md"
  else
    echo "" >> index.md
    echo "## Articles" >> index.md
    echo "" >> index.md
    echo "$FULL_LINK" >> index.md
    echo "Added Articles section to index.md"
  fi
fi

# --- Preview ---
echo ""
echo "================================"
echo "Title:  $TITLE"
echo "Date:   $POST_DATE"
echo "File:   $POST_FILE"
echo "URL:    https://sgkevin1980.github.io/${POST_DATE//-/\/}/${SLUG}.html"
echo "================================"
echo ""

# --- Commit and push ---
read -p "Publish now? (Y/n): " PUBLISH
if [ "$PUBLISH" = "n" ] || [ "$PUBLISH" = "N" ]; then
  echo "Saved locally. Run 'git add . && git commit && git push' when ready."
  exit 0
fi

git add "$POST_FILE" index.md
git commit -m "Publish: $TITLE"
git push origin main

echo ""
echo "Published! Site will rebuild in ~1-2 minutes."
echo "URL: https://sgkevin1980.github.io/${POST_DATE//-/\/}/${SLUG}.html"

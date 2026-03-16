# Kevin Ye's Tech Blog

GitHub Pages site: https://sgkevin1980.github.io/

## Quick Start: Publish an Article

```bash
cd sgkevin1980.github.io
./publish.sh ~/path/to/my-article.md
```

That's it. The script handles everything:
front matter, file naming, index update, commit, and push.

## How It Works

```
Your markdown file
       |
       v
./publish.sh
       |
       | 1. Extracts title from first # heading
       | 2. Generates URL slug from title
       | 3. Adds Jekyll front matter on top
       | 4. Copies to _posts/YYYY-MM-DD-slug.md
       | 5. Adds link to index.md
       | 6. Commits and pushes to GitHub
       |
       v
Live at sgkevin1980.github.io (~1-2 min)
```

## Publish Options

```bash
# Publish with today's date
./publish.sh ~/Documents/my-article.md

# Publish with a specific date
./publish.sh ~/Documents/my-article.md 2026-03-20
```

## Markdown Requirements

Your markdown file just needs one thing:
a `# Title` on the first heading line.

```markdown
# My Article Title

Content goes here...
```

The script will convert it to:

```markdown
---
layout: default
title: "My Article Title"
date: 2026-03-16
---

# My Article Title

Content goes here...
```

## Manual Publish (without script)

1. Add front matter to your markdown:

   ```markdown
   ---
   layout: default
   title: "Your Title"
   date: 2026-03-16
   ---
   ```

2. Save as `_posts/2026-03-16-your-title.md`

3. Add a link in `index.md`:

   ```markdown
   - [Your Title]({% link _posts/2026-03-16-your-title.md %})
   ```

4. Commit and push:

   ```bash
   git add _posts/ index.md
   git commit -m "Publish: Your Title"
   git push origin main
   ```

## Repo Structure

```
sgkevin1980.github.io/
+-- _config.yml           # Jekyll config (Cayman theme)
+-- assets/css/style.scss # Custom CSS overrides
+-- index.md              # Home page with article list
+-- publish.sh            # One-command publish script
+-- _posts/               # Published articles
|   +-- 2026-03-16-rosa-aro-zero-egress.md
+-- README.md             # This file
```

## Theme & Styling

- **Theme**: Cayman (full-width, green header)
- **Custom CSS**: `assets/css/style.scss`
  - 960px content width
  - Dark code blocks
  - Green-header tables with alternating rows
  - Yellow callout blockquotes
  - Clean heading spacing

To modify styling, edit `assets/css/style.scss`
and push — changes apply to all posts.

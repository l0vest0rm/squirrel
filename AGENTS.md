# Repo Conventions

## Rime Config Source Of Truth

- Treat `custom/` as the source of truth for Rime configuration templates.
- Installation should copy files from `custom/` into `~/Library/Rime/`.
- Do not edit `~/Library/Rime/build/*` directly; those are generated files.
- When changing Rime settings for this repo, prefer editing files under `custom/` first.

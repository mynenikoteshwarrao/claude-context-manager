# dist/ — package-manager templates

These files are committed here so they version with the main repo. The release workflow (`.github/workflows/release.yml`) copies them into the sibling repos `homebrew-ccm` and `scoop-ccm` and rewrites the `sha256` / `hash` and `version` fields.

Do not edit the live files in those sibling repos by hand — edit here, and the next tag push will regenerate them.

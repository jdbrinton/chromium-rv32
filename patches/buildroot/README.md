# Buildroot patches

This directory is reserved for any patches we need against the pinned
Buildroot tree (currently `2026.02.1`). At the time of writing **there
are no required Buildroot patches** — our customisation lives entirely
in `configs/buildroot/` as a `BR2_EXTERNAL` tree.

If a future change cannot be expressed as a defconfig + overlay (e.g. a
fix to a Buildroot package recipe), drop the patch here and update
`scripts/apply-patches.sh` so it's picked up automatically.

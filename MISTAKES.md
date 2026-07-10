# Mistakes

- 2026-07-10: An unbounded `fd` search from `/nix/store` scanned 7.6 GB while looking for an old Zig standard-library file. Inspect process cwd/argv/I/O before stopping it, then query a known package output or upstream source directly instead of recursively scanning the store.
- 2026-07-10: Raw `nix develop -c zig build test` materialized Capy's lazy legacy macOS SDK dependency on Linux and failed before the focused test. Use the canonical Nix test derivation with a temporary compile filter for focused red/green evidence until that SDK package is migrated.

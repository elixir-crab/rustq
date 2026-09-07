## Alias resolver review follow-up

- Rust metadata now retains module paths for `use` items and type aliases.
- Expansion explicitly rejects nested aliases rather than merging them into a global name table. Root alias qualification ignores imports in nested modules.
- Parsed alias maps are cached by configured source paths with content-hash invalidation; same-size edits are tested.
- The real slider fixture resolves its aliases from source and uses ordinary guard method calls; the old explicit mutable-borrow workaround is no longer required.

Still limited: root aliases from multiple files share a lookup table (conflicting definitions are rejected); glob imports/reexports and full module resolution are not implemented. Alias expansion rebuilds normalized types from AST and does not preserve every rich field of the original metadata. These remain review risks, not completed features.

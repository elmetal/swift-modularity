# Changelog

The versions follow [Semantic Versioning](https://semver.org). Before 1.0.0, a minor version may
change the command-line options and the text output; the JSON output changes incompatibly only
with a new `schemaVersion`.

## 0.0.1

The first release.

### Measures
- The visibility matrix, VFI/VFO, propagation cost, cyclic groups, the architecture
  classification (core-periphery, borderline, multi-core, hierarchical) and the core-periphery
  and median partitions of Baldwin, MacCormack and Rusnak (2014), with the paper's thresholds or
  others (`--size-threshold`, `--sensitivity-threshold`, `--dominance-threshold`).
- For each cyclic group, the dependencies whose removal splits it, most effective first.
- For each directory of a module, whether it could become a target of its own, and what blocks it.

### Graphs
- Targets of a Swift package, from `Package.swift`.
- Files of a module, from SwiftSyntax without compiling: types, top-level declarations and macros,
  members reached through implicit `self`, `self.`, `Self.` and type names, inherited members,
  and file-private declarations. A target's files follow the `sources:` and `exclude:` of its
  manifest.

### Commands
- `files`: directories of Swift files as one module (the default command).
- `package`: the target graph of a package, then the file graph of each target.
- `diff`: the changes between two revisions of a git repository, written as in `git diff`.
- `swift package modularity`: the command plugin, which runs `package`, `files` and `diff`.
- Output as text, JSON (with `schemaVersion` 1), and notes for Xcode and GitHub Actions.
- `modularity.toml` for defaults.

### Known limits
- Members reached through a value (`value.member`, `.implicitMember`) are not resolved, so the
  file graph misses dependencies and propagation cost is a lower bound.
- `diff` does not see the files of git submodules in committed revisions.
- The command plugin cannot write `--output` into the package; redirect the output instead.

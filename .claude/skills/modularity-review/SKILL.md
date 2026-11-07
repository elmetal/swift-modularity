---
name: modularity-review
description: Measure the dependency structure of Swift code with swift-modularity (propagation cost, dependency cycles between files, core-periphery architecture) and plan how to untangle it. Use when asked about modularity, coupling, dependency cycles, architecture, or splitting a Swift module or package.
---

# Review Swift modularity

Use `swift-modularity-cli` to measure how changes spread through a Swift codebase, then turn the
results into a plan. Run the CLI yourself; don't ask the user to run it.

## Running the tool

Use `swift-modularity-cli` if it is on `PATH`. Otherwise build it from a checkout of
https://github.com/elmetal/swift-modularity (`swift build -c release`, then use
`.build/release/swift-modularity-cli`), or in a package that depends on it run
`swift package modularity` with the same options. `--help` on each command lists every option.

Results go to stdout and diagnostics to stderr. A `modularity.toml` in the project may set
defaults; command-line options win.

```bash
# A Swift package: target graph, then the files of each target
swift-modularity-cli package
swift-modularity-cli package --include-tests --limit 0

# One module given as directories (an Xcode app target, for example)
swift-modularity-cli files MyApp --exclude '**/Generated/**'

# The reordered DSM for a small module; machine-readable output
swift-modularity-cli files Sources/Core --matrix
swift-modularity-cli package --format json

# What a branch changed (default: the merge base with the default branch → the working tree)
swift-modularity-cli diff
swift-modularity-cli diff main...feature -- MyApp
```

To review a branch or a pull request, start with `diff`: it lists the cyclic groups that are new
or grew, and the new dependencies inside them that close the cycle. Focus the review on those
rather than on cycles that were already there.

## Reading the results

- **Propagation cost**: the share of the module a change can reach, directly or indirectly. Compare
  it between targets of similar size or over time; a module of n files is at least 1/n.
- **Architecture**: core-periphery (one large cyclic group, the Core), borderline, multi-core
  (several large cyclic groups) or hierarchical (no large cycles).
- **Cyclic groups**: files that all depend on each other. Each dependency inside a group is listed
  with the first reference that creates it (`file → file  \`Symbol\` line N`).
- **Groups**: Shared (foundation), Core / Central, Peripheral, Control (top-level code).

The file graph comes from syntax only. Members reached through a value (`x.helper()`) or an
implicit member expression (`.default`) are not resolved, so some real dependencies are missing:
a cyclic group can be larger than reported, and removing the listed references may not break it.
Check by reading the code before claiming a dependency exists or not, or that a change breaks a
cycle. Small cycles (a type and its extension, a view and its model) are usually fine; don't
propose changes only to reach zero cycles.

## Writing the plan

For each cyclic group, starting with the Core and the largest groups:

1. Start from the dependencies the tool lists under "Removing one of these dependencies splits
   it" (most effective first): usually a low-level file that refers back to a high-level one (a
   model that knows a view, a utility that knows a feature). Read the referenced line and the other
   references between the two files. A group listed as split by no single dependency needs a
   larger change (splitting a file or a type).
2. Propose a concrete change for each: move the type to the file or module it belongs with, extract
   a protocol into the lower file and let the higher one conform, inject a closure instead of
   referring to the caller, or split a file that mixes layers.
3. After a change, rerun the tool to confirm the group split: a dependency the tool cannot see
   can keep the cycle. Say what the change does to the structure (which files leave the group, whether the module could
   then be split into targets) and its risk (public API changes, behavior to preserve, tests to run).

To split a module into targets, start from "Directories as targets": candidate lower targets
become libraries below, candidate higher targets features on top; for a blocked directory, plan
the listed dependencies to remove or the files to move with it. Say which declarations would have
to become `public`, and that the compiler confirms a candidate only once the directory is moved.

Also point out Shared files with a high VFO (foundation code depending on much) and targets whose
propagation cost stands out. Order the plan by impact. Don't change code until the user has agreed
to the plan, unless they asked you to go ahead.

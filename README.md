# swift-modularity

A Swift tool that measures the dependency structure of Swift code: **propagation cost**, **cyclic
groups** and **core-periphery architecture**, computed exactly as defined in the research
literature, at two levels: the targets of a Swift package, and the files of each module.

It answers: how far can a change spread, which files are tangled in cycles, which dependency to
remove to split a cycle, and which directories could become a target of their own.

## Installation

Requires Swift 6.1 or later, on macOS 13 or later or Linux.

### Command-line tool
```bash
git clone https://github.com/elmetal/swift-modularity.git
cd swift-modularity
swift build -c release
cp .build/release/swift-modularity-cli /usr/local/bin/
```

### SwiftPM command plugin
Add the package as a dependency and run `swift package modularity`:

```swift
dependencies: [
    .package(url: "https://github.com/elmetal/swift-modularity.git", branch: "main"),
],
```

## Usage

```bash
# A Swift package: the target graph, then the file graph of every target (except tests)
swift-modularity-cli package
swift-modularity-cli package --package-path ../MyPackage --include-tests
swift-modularity-cli package --target App --target Core
swift-modularity-cli package --targets-only

# Any directories of Swift files, analyzed as one module (for example an Xcode app target)
swift-modularity-cli files MyApp/Sources
swift-modularity-cli MyApp/Sources --exclude '**/Generated/**'   # `files` is the default command

# The reordered DSM, all elements, JSON
swift-modularity-cli package --matrix --limit 0
swift-modularity-cli package --format json

# What changed: this branch and its uncommitted changes against the default branch, two revisions
swift-modularity-cli diff
swift-modularity-cli diff main...feature
swift-modularity-cli diff v1.0..v2.0 -- MyApp/Sources   # after --: directories, as `files` takes them
```

Each module's report gives its size, propagation cost, architecture and partition, then its
cyclic groups and its directories as targets; the excerpts below show how to read them.

## What is measured

The method is Baldwin, MacCormack and Rusnak (2014), *"Hidden structure: Using network methods to
map system architecture"*, Research Policy 43(8), 1381–1397, building on MacCormack, Rusnak and
Baldwin (2006), *"Exploring the structure of complex software designs: An empirical study of open
source and proprietary code"*, Management Science 52(7). See [ARCHITECTURE.md](ARCHITECTURE.md)
for the exact definitions and how each is computed.

- **Dependency (first-order DSM)**: element A depends on B when a change to B may require a change
  to A. Targets: the target dependencies in `Package.swift`. Files: A refers to a name declared in B
  (see [How file dependencies are found](#how-file-dependencies-are-found)).
- **VFO / VFI** (visibility fan-out / fan-in): how many elements an element depends on, and how many
  depend on it, directly or indirectly, counting itself.
- **Propagation cost**: the density of the visibility matrix, `Σ VFO / n²`, the fraction of the
  system that a change to a randomly chosen element can potentially affect. Lower is more modular.
  Since every element counts itself, a module of n files has a propagation cost of at least 1/n, so
  compare modules of similar size, or the same module over time.
- **Cyclic groups**: sets of elements that all depend on each other (strongly connected
  components of two or more elements). The largest is the **Core**.
- **Architecture**, from the size of the Core with the paper's thresholds (x = 5%, y = 1%,
  z = 50%):
  - *hierarchical*: the Core is under 4% of the system (or there is no cyclic group);
  - *multi-core*: the Core is not at least 1.5 times the next largest cyclic group;
  - *borderline core-periphery*: the Core is 4% to 6% of the system;
  - *core-periphery*: the Core is 6% or more.

  `--size-threshold`, `--sensitivity-threshold` and `--dominance-threshold` change x, y and z. The
  paper chose its values for its dataset of 1,286 releases of 17 systems, most with hundreds to
  thousands of files, and notes that other environments may need others. The classification
  describes the shape of a system; it is not a quality judgment. In a module of a few dozen files
  one 2-file cycle is already over 4%.
- **Partition**: each element is *Shared* (widely depended on, depends on little), *Core*,
  *Peripheral* (little in either direction) or *Control* (depends on much, depended on little), by
  comparing its VFI and VFO with the Core's. Hierarchical and multi-core systems are partitioned
  by the median VFI and VFO instead (*Shared-M*, *Central*, *Peripheral-M*, *Control-M*), as the
  paper does.

### Reading the results

- Each **cyclic group** lists its members and the dependencies whose removal splits it (see
  [Dependencies that split a cycle](#dependencies-that-split-a-cycle)). Swift allows any file of a
  module to use any other, so cycles between files are
  legal and common, and a small one (a type and its extension, a view and its model) is usually
  harmless. A large group matters because its files may have to change or be understood together,
  and it blocks splitting the module. A reported group can be smaller
  than the real one when the tool misses a dependency.
- **Propagation cost** is a system-level number: track it over time, or compare targets of similar
  size. It is a lower bound at file level, since the tool misses some dependencies. In
  MacCormack et al. (2006) it differs widely between systems with the same function. MacCormack and
  Sturtevant (2016), "Technical debt and system architecture: The impact of coupling on
  defect-related activity" (Journal of Systems and Software 120), found more defect-related
  activity in files with higher coupling, in particular in the Core.
- **Control** elements are top-level code (commands, view controllers, composition roots);
  **Shared** elements are the foundation everything relies on. A Shared element that depends on a
  lot, or a Core that keeps growing, is worth a look.

## Dependencies that split a cycle

For each cyclic group, the tool removes each dependency between two members in turn and recomputes
the cycles among them exactly. A dependency is listed when the largest group left is smaller than
the group, most effective first (then the fewest references to remove):

```
    1. 3 files (Core): Library/Catalog.swift, Library/Library.swift, Library/Shelf.swift
       Removing one of these dependencies splits it:
         Library/Catalog.swift → Library/Library.swift  `Library` line 8 (1 reference): no cycle left
         Library/Library.swift → Library/Shelf.swift  `Shelf` line 3 (1 reference): no cycle left
         Library/Shelf.swift → Library/Catalog.swift  `Catalog` line 2 (1 reference): no cycle left
```

A dependency is all the references from one file to the other; removing them usually means moving
a declaration to the other file or a lower one, introducing a protocol that the lower file owns, or
passing a closure instead of naming the caller. A group with no such dependency is listed as one
that no single dependency splits.

A dependency the tool cannot see (a member reached through a value) can close the cycle another
way, which is likelier in modules whose types are extended across many files: rerun the analysis
after the change to confirm.

## Directories that could become targets

Each directory of a module with two or more files is checked as a target of its own. Splitting it
off works without a cycle between targets when dependencies cross its boundary in one direction:

- **lower target**: none of its files depends on the rest of the module, so the rest can depend on
  it (a library or layer below);
- **higher target**: nothing else in the module depends on it, so it can depend on the rest (a
  feature on top);
- otherwise it is **blocked**, and the dependencies to remove in the cheaper direction are listed,
  or the files it needs that could move with it.

```
  Directories as targets (...):
    Models/ (2 files): candidate lower target — depends on nothing else here; 5 dependencies (8 references) from other files would use it
    Util/ (2 files): candidate lower target — depends on nothing else here; 1 dependency (2 references) from other files would use it
    Features/Search/ (2 files): blocked — as a higher target, remove 1 dependency (2 references):
        App.swift → Features/Search/SearchView.swift  `SearchView` line 4 (2 references)
```

The references that cross the boundary are the declarations that would have to become `public`.
These are candidates: a dependency the tool cannot see can block one; the compiler settles it
when the directory is moved.

## Changes between revisions

`diff` analyzes two revisions of a git repository and reports what changed: elements and
dependencies added and removed, propagation cost, architecture, and the cyclic groups that are
new, grew, shrank or are no longer cycles. The revisions are written as in `git diff`:

| Argument | Compares |
| --- | --- |
| (none) | the merge base of the default branch (`origin/HEAD`, else `main` or `master`) and `HEAD`, with the working tree |
| `A...B` | the merge base of A and B, with B (an empty side is `HEAD`) |
| `A..B` | A with B |
| `A` | A with the working tree |

Both sides are analyzed on the spot, with the same version of the tool and the same
`modularity.toml`, so no report has to be kept between runs, and a change to the tool never makes
the two sides incomparable. A revision is checked out into a temporary git worktree; the working
tree is not touched. Without paths, the package in `--package-path` is analyzed as `package` does;
after `--`, the paths are analyzed as one module, as `files` does. `diff` runs from the
command-line tool, not from the command plugin.

```
App (files) — App
  Files: 3 → 4 (+1)
    added: D.swift
  Dependencies: 2 → 4 (+2, −0)
  Propagation cost: 66.7% → 81.2% (+14.6 points)
  Architecture: hierarchical → core-periphery
  Largest cyclic group: 0 → 3 files

  Cyclic groups that changed:
    New: group 1, 3 files: A.swift, B.swift, C.swift
      New dependencies inside:
        B.swift → C.swift  `C` line 2 (1 reference): removing it splits the group, no cycle left
```

Groups are matched by their members: a group continues the earlier group it shares the most
members with (at least two). Its new dependencies are the dependencies between its members that
the earlier revision did not have, the ones whose removal splits the group first; those are where
a change of the branch closed a cycle. Files are matched by path, so a renamed file is removed
and added.

## How file dependencies are found

Nothing is compiled: each file is parsed with [SwiftSyntax](https://github.com/swiftlang/swift-syntax),
the names it declares are collected, and file A depends on file B when A refers to:

- a type declared in B (struct, class, enum, actor, protocol, typealias), including nested types
  written as `Outer.Inner`, or as `Inner` inside `Outer` or one of its extensions;
- a top-level function, variable or macro declared in B;
- a member declared in B (in the type or an extension of it), reached through implicit `self`
  inside the type or its extensions, through `self.` / `Self.`, or through a type name
  (`Config.timeout`). Members inherited from protocols and superclasses declared in the module are
  found too; the type's own member hides an inherited one, and overloads are told apart by their
  argument labels (allowing default arguments and trailing closures).

An extension depends on the file declaring the extended type. `private` and `fileprivate`
declarations are visible only in their own file, and DocC catalogs (`*.docc`) are skipped.
Parameters, local variables and generic parameters shadow other names. Known limits:

- **Members reached through a value are not resolved.** `text.indented()`, where `indented` is
  added by an extension in another file, or an implicit member expression such as `.default`, needs
  the type of the value. These are most of the dependencies the tool misses, so propagation cost is
  a lower bound.
- Overloads with the same argument labels but different types depend on every file declaring one.
- Declarations and references inside `#if` count whatever the condition.
- `files` treats everything it is given as one module; analyze each module separately (or use
  `package`) so that equal names in different modules do not create false dependencies.

## Configuration

`modularity.toml` in the current directory or a parent directory sets defaults; command-line
options override it and `--exclude` patterns are added to its `exclude`.

```toml
exclude = ["**/Generated/**"]   # --exclude (glob patterns, repeatable)
include_tests = false           # --include-tests (package)
size_threshold = 0.05           # --size-threshold
sensitivity_threshold = 0.01    # --sensitivity-threshold
dominance_threshold = 0.5       # --dominance-threshold
limit = 10                      # --limit (elements listed per group in text output, 0 for all)
```

`--no-config` ignores the file.

## Reports, not verdicts

swift-modularity reports measurements and the dependencies that split cycles; it does not fail
anything. No threshold on cycles
or propagation cost has been shown to improve code quality: the studies relate the Core and
coupling to maintenance costs, they do not define a level that is acceptable. A gate such as "no
cycles" would mostly push toward merging files to hide them. So there are no warnings and no
failing exit status (invalid arguments exit with 64).

### Notes in Xcode and on pull requests
`--format xcode` and `--format github` write a note (not a warning) at the most effective
dependency to remove in each cyclic group, at the reference that creates it:

```
/path/to/MyApp/Models/Book.swift:3:17: note: removing the dependency on Models/Author.swift (`Author`, 1 reference) splits cyclic group 2 of 2 files in MyApp: no cycle left [swift-modularity]
```


Use `xcode` in a Run Script build phase (with `ENABLE_USER_SCRIPT_SANDBOXING = NO`, or the source
directories as input files) and `github` in a GitHub Actions step
(`swift package modularity --format github`).

With `diff`, the notes are only at the new dependencies that close or grow a cyclic group, which
suits a pull request: the cycles that were already there are not repeated on every change.

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 0   # the merge base needs the history
- run: swift-modularity-cli diff origin/${{ github.base_ref }}...HEAD --format github
```

To follow the measures over time, compare any two revisions, such as two release tags
(`diff v1.0..v2.0`); `--format json` gives the same comparison for other tools.

### AI assistants
The text output gives cycles with `file:line` references and the role of every file, which an AI
assistant can read directly. For [Claude Code](https://claude.com/claude-code), copy
[`.claude/skills/modularity-review/SKILL.md`](.claude/skills/modularity-review/SKILL.md) to
`.claude/skills/modularity-review/` in your project and ask Claude to review the modularity (or run `/modularity-review`).

## License
MIT

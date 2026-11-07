# swift-modularity

A Swift tool that measures the dependency structure of Swift code: **propagation cost**, **cyclic
groups** and **core-periphery architecture**, computed exactly as defined in the research
literature, at two levels: the targets of a Swift package, and the files of each module.

Where [swift-similarity](https://github.com/elmetal/swift-similarity) answers "which code is
duplicated?", swift-modularity answers "how far does a change spread, and which files are tangled
in cycles?".

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
```

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
  paper chose its values for its dataset of 1,286 releases of 17 systems and notes that other
  environments may need others.
- **Partition**: each element is *Shared* (widely depended on, depends on little), *Core*,
  *Peripheral* (little in either direction) or *Control* (depends on much, depended on little), by
  comparing its VFI and VFO with the Core's. Hierarchical and multi-core systems are partitioned
  by the median VFI and VFO instead (*Shared-M*, *Central*, *Peripheral-M*, *Control-M*), as the
  paper does.

### Reading the results

- Each **cyclic group** lists the dependencies between its members, with the first reference that
  creates each one. Removing references along these dependencies (moving a type, introducing a
  protocol in a lower file, splitting a file) breaks the cycle. Swift allows any file of a module to
  use any other, so cycles between files are legal and common; they matter because every file in a
  group may have to change or be understood together, and they block splitting the module.
- **Propagation cost** is a system-level number: track it over time, or compare targets. In
  MacCormack et al. (2006) it differs widely between systems with the same function. MacCormack and
  Sturtevant (2016), "Technical debt and system architecture: The impact of coupling on
  defect-related activity" (Journal of Systems and Software 120), found more defect-related
  activity in files with higher coupling, in particular in the Core.
- **Control** elements are top-level code (commands, view controllers, composition roots);
  **Shared** elements are the foundation everything relies on. A Shared element that depends on a
  lot, or a Core that keeps growing, is worth a look.

## How file dependencies are found

Nothing is compiled: each file is parsed with [SwiftSyntax](https://github.com/swiftlang/swift-syntax),
the names it declares are collected, and file A depends on file B when A refers to:

- a type declared in B (struct, class, enum, actor, protocol, typealias), including nested types
  written as `Outer.Inner`, or as `Inner` inside `Outer` or one of its extensions;
- a top-level function, variable or macro declared in B.

An extension depends on the file declaring the extended type. Parameters, local variables, generic
parameters and members of the enclosing types shadow top-level names. Known limits:

- **Members are not resolved.** `value.helper()`, where `helper` is added by an extension in another
  file, does not create a dependency on that file (it needs type information). Dependencies are
  therefore a subset of the real ones for code that relies on extension methods, so propagation cost
  is a lower bound in that respect.
- Members inherited from superclasses or protocols do not shadow top-level names of the same name.
- Declarations inside `#if` count whatever the condition.
- A name declared in several files (overloaded top-level functions) depends on all of them.
- `files` treats everything it is given as one module; analyze each module separately (or use
  `package`) so that equal names in different modules do not create false dependencies.

## Configuration

`modularity.toml` in the current directory or a parent directory sets defaults; command-line
options override it and `--exclude` patterns are added to its `exclude`.

```toml
exclude = ["**/Generated/**"]   # --exclude (glob patterns, repeatable)
include_tests = false           # --include-tests (package)
fail_on_cycles = false          # --fail-on-cycles
max_propagation_cost = 0.3      # --max-propagation-cost
size_threshold = 0.05           # --size-threshold
sensitivity_threshold = 0.01    # --sensitivity-threshold
dominance_threshold = 0.5       # --dominance-threshold
limit = 10                      # --limit (elements listed per group in text output, 0 for all)
```

`--no-config` ignores the file.

## Xcode, CI and AI assistants

### Warnings
`--format xcode` and `--format github` write one warning per dependency inside a cyclic group, at
the reference that creates it:

```
Sources/App/FilesCommand.swift:23:31: warning: `CommonOptions` (SwiftModularityCLI.swift) depends back on this file, directly or indirectly: cyclic group 1 of 3 files in App, the Core (100.0% of the module) [swift-modularity]
```

Use `xcode` in a Run Script build phase (with `ENABLE_USER_SCRIPT_SANDBOXING = NO`, or the source
directories as input files), and `github` in GitHub Actions to annotate pull requests.

### Failing a build
- `--fail-on-cycles`: exit with status 1 when any analyzed module has a cyclic group.
- `--max-propagation-cost 0.3`: exit with status 1 when a module's propagation cost is above 30%.

The results are written as usual; the reasons go to standard error. Invalid arguments exit with 64.

```yaml
- name: Check modularity
  run: swift package modularity --format github --fail-on-cycles
```

### AI assistants
The text output gives cycles with `file:line` references and the role of every file, which an AI
assistant can read directly. For [Claude Code](https://claude.com/claude-code), copy
[`.claude/skills/check-modularity/SKILL.md`](.claude/skills/check-modularity/SKILL.md) to
`.claude/skills/check-modularity/` in your project and ask Claude to check the modularity.

## License
MIT

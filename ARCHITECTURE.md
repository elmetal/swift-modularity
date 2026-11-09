# swift-modularity Architecture

## Overview

swift-modularity builds a dependency graph (targets of a package, or files of a module), then
computes the measures of:

- MacCormack, Rusnak and Baldwin (2006), "Exploring the structure of complex software designs: An
  empirical study of open source and proprietary code", Management Science 52(7): the visibility
  matrix and propagation cost.
- Baldwin, MacCormack and Rusnak (2014), "Hidden structure: Using network methods to map system
  architecture", Research Policy 43(8): visibility fan-in/fan-out, cyclic groups, the architecture
  classification and the core-periphery / median partitions (methodology in its Appendix A).

All measures are exact for the graph: nothing is sampled or approximated. The only approximation is
the graph itself at file level, which is found from syntax without type checking.

## Definitions

Let A be the first-order DSM (`A[i][j] = 1` when i depends on j) of n elements.

| Measure | Definition | Code |
| --- | --- | --- |
| Visibility matrix V | Σ Aᵏ for k = 0…n, entries > 0 set to 1 (reflexive transitive closure: "a change to an element will always affect itself") | `VisibilityMatrix` |
| VFOᵢ | row sum of V | `VisibilityMatrix.fanOut` |
| VFIᵢ | column sum of V | `VisibilityMatrix.fanIn` |
| Propagation cost | Σ VFOᵢ / n² (= Σ VFIᵢ / n²) | `VisibilityMatrix.propagationCost` |
| Cyclic group | set of elements that all depend on each other: a strongly connected component of 2+ elements | `StronglyConnectedComponents`, `ModularityAnalysis.cyclicGroups` |
| Core | the largest cyclic group, of size n_C | `ModularityAnalysis` |

Architecture (Appendix A, step 7), with n_~C the size of the next largest cyclic group and the
paper's x = 5%, y = 1%, z = 50%:

1. (a) n_C ≥ (x − y)·n, (b) n_C ≥ (1 + z)·n_~C, (c) n_C ≥ (x + y)·n
2. a, b and c: core-periphery; a and b: borderline core-periphery; a only: multi-core; not a:
   hierarchical. With no cyclic group, the system is hierarchical.

Partition (steps 10 and 11). For core-periphery and borderline systems, with VFI_C and VFO_C those
of the Core: Shared VFI ≥ VFI_C and VFO < VFO_C; Peripheral VFI < VFI_C and VFO < VFO_C; Control
VFI < VFI_C and VFO ≥ VFO_C. For multi-core and hierarchical systems, the same comparisons against
the median VFI and VFO, with Central for VFI ≥ median and VFO ≥ median.

The paper's three non-Core groups leave out elements outside the Core whose VFI and VFO both
reach the Core's. That is only possible for elements unrelated to the Core (an element that
depends on the Core has a lower VFI than the Core; one the Core depends on has a lower VFO), and
this tool labels them Central.

Both steps put an element equal to the threshold on the high side (≥). When a median is 1, its
minimum (every element counts itself), every element is high on that axis, so the median view has
no Peripheral-M or Control-M (median VFI 1) or no Shared-M or Peripheral-M (median VFO 1). That
follows the paper and is kept. When no element depends on another, both medians are 1 and every
element is Central; `ModularityAnalysis.isPartitioned` is then false, the text output prints
`Partition: none`, and the JSON keeps each element's `group` with `isPartitioned: false`.

The reordered DSM (step 12) lists the groups in the order Shared, Core (or Central), Peripheral,
Control, each sorted by VFI descending, then VFO ascending (then name, for a stable order).

## Computation

1. **Strongly connected components**: Tarjan's algorithm, iterative (deep graphs do not overflow the
   stack). It returns the components in reverse topological order.
2. **Visibility**: all members of a component have the same row of V, so each component's row is
   the union of its members and the rows of the components it depends on, built in reverse
   topological order as bit sets. Time O(c·(n + e)/64) for c components and e edges, memory
   O(c·n/8) bytes. VFI is accumulated from the rows (each component adds its size to every column
   in its row).
3. **Classification and partition** from the component sizes and VFI/VFO.

Tests check V against Figure 4 of the paper and against Warshall's algorithm on random graphs.

## Dependencies that split a cyclic group

`CycleBreaking` takes each cyclic group's own subgraph and, for each dependency between two
members, recomputes the strongly connected components without it (Tarjan, O(V + E) per
dependency, so O(E · (V + E)) per group). A dependency is reported when the largest component
left is smaller than the group; they are ranked by the reduction, then by the number of
references, then by name. Pairs or sets of dependencies are not searched: the smallest set that
removes every cycle (a minimum feedback arc set) is NP-hard, and one dependency at a time is what
one change does.

## Changes between revisions

`diff` resolves the two sides with git (`merge-base` for `A...B` and the default range), checks
out each revision into a temporary directory (`git read-tree` into a temporary index file, then
`git checkout-index --prefix`: nothing is written into `.git`, so this works in the command
plugin's sandbox), runs the same analysis as `package` or `files` with the directory standing for
the current one, and rewrites the paths of the report to the working tree's. Run by the plugin,
the working tree's targets come from the plugin's JSON, since `dump-package` would wait for the
package SwiftPM holds, and the other revisions' manifests are read with
`dump-package --disable-sandbox`, since SwiftPM's manifest sandbox cannot start inside the
plugin's. `ModularityDiff` then compares the two reports:
modules by level and name, elements by name, dependencies by their two ends. Each cyclic group of
the newer side continues the older group with which it shares the most members, at least two
(two members that still depend on each other); a newer group without one is new, an older group
that no newer group continues is resolved. The new dependencies of a group are its internal
dependencies absent from the older graph, ordered as its `breakingDependencies`.

## Directories as targets

`Extraction` takes every directory prefix of the file names (relative to the module) with at least
two files and fewer than all of them. For each, it collects the dependencies leaving it and
entering it; with none leaving, the directory is a candidate lower target, with none entering a
candidate upper target. For blocked directories the files the directory needs, directly or
indirectly, come from the visibility matrix (what would move with it to make a lower target).
For each cyclic group with members on both sides of a blocked directory's boundary, the groups
left when the outgoing dependencies are removed together come from `CycleBreaking`; removing the
incoming ones instead leaves the same groups, the cycles within each side.
Candidates come first (largest first), then blocked directories by the fewest dependencies to
remove in the cheaper direction. Directories are the only sets considered: they are how a codebase
already groups its files, and searching all sets of files that could be split is not useful to
report.

## Building the graphs

**Targets** (`PackageDescription`, `PackageLoader`): `swift package dump-package`, or the JSON that
the command plugin writes from SwiftPM's plugin API (a plugin cannot run SwiftPM on its own
package). Only dependencies on targets of the same package are edges; products of other packages
are outside the system. A target's files are the Swift files under its directory within its
`sources:` and outside its `exclude:`, as SwiftPM compiles them: from `dump-package`, the two
lists are applied to the files found; the plugin lists the files SwiftPM gives it (`sourceFiles`).
`--exclude` and `modularity.toml` patterns are applied on top.

**Files** (`FileDependencyGraphBuilder`): two passes over the SwiftSyntax trees, parsed in parallel.

1. `DeclarationCollector` records each file's qualified type names (`Outer.Inner`), top-level
   functions, variables and macros, the members of every type (including those declared in
   extensions) with their shape (a value, a nested type, or a function or enum case with its
   parameters' labels and defaults), the inheritance clauses, and which declarations are
   file-private (`private`, `fileprivate`, inside a private type or a `private extension`).
   Function bodies are skipped: what they declare is local.
2. `SymbolTable` merges the files: only declarations other files can see are entered, and the
   names in inheritance clauses are resolved to the module's protocols and superclasses.
3. `ReferenceCollector` walks each file with a stack of enclosing types and a stack of local scopes
   (parameters, generic parameters, pattern bindings, closure parameters, implicit `newValue`,
   `oldValue` and `error`). A type name `X` inside `A.B` resolves to `A.B.X`, `A.X` or `X`, the
   first that exists (the file's own declarations first). An unqualified value name that is not
   local is looked up as a member of the enclosing types, innermost first, then as a type, then as
   a top-level value. `self.m` and `Self.m` look up `m` in the innermost type; `A.B.m` resolves the
   longest prefix that is a type, then `m` as its member. Member lookup goes level by level: the
   type and its extensions, then its supertypes; the first level with a member whose shape fits
   the use (a call's argument labels and trailing closures, or a plain value) wins, as in Swift's
   lookup. Arguments of `@_spi`, `@objc` and similar attributes are not references. The first
   reference to each other file is kept, with its line and column, and references are counted.

## Layout

```
Sources/swift-modularity/
  Graph/      DependencyGraph, StronglyConnectedComponents, VisibilityMatrix (+ BitSet)
  Analysis/   ModularityAnalysis (classification, partition, DSM order), CycleBreaking, Extraction
  Syntax/     FileDependencyGraphBuilder (DeclarationCollector, ReferenceCollector)
  Package/    PackageDescription, PackageLoader
  Config/     ModularityConfig (modularity.toml)
  Diff/       RevisionRange, Git (merge base, temporary exports), ModularityDiff
  Output/     ModularityReport (JSON model), TextFormatter, DiagnosticFormatter (notes), DiffFormatter
  Utils/      FileReader, ExcludePattern, concurrentMap
Sources/swift-modularity-cli/   `files`, `package` and `diff` commands
Plugins/ModularityPlugin/       `swift package modularity`
```

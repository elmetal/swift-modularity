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

## Building the graphs

**Targets** (`PackageDescription`, `PackageLoader`): `swift package dump-package`, or the JSON that
the command plugin writes from SwiftPM's plugin API (a plugin cannot run SwiftPM on its own
package). Only dependencies on targets of the same package are edges; products of other packages
are outside the system.

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

The accuracy of this graph against the compiler's index is measured in
[Evaluation/GraphAccuracy](Evaluation/GraphAccuracy).

## Layout

```
Sources/swift-modularity/
  Graph/      DependencyGraph, StronglyConnectedComponents, VisibilityMatrix (+ BitSet)
  Analysis/   ModularityAnalysis (classification, partition, DSM order)
  Syntax/     FileDependencyGraphBuilder (DeclarationCollector, ReferenceCollector)
  Package/    PackageDescription, PackageLoader
  Config/     ModularityConfig (modularity.toml)
  Output/     ModularityReport (JSON model), TextFormatter
  Utils/      FileReader, ExcludePattern (shared with swift-similarity), concurrentMap
Sources/swift-modularity-cli/   `files` and `package` commands
Plugins/ModularityPlugin/       `swift package modularity`
```

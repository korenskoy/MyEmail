---
name: swiftui-view-refactor
description: Refactor and review SwiftUI view files with strong defaults for small dedicated subviews, MV-over-MVVM data flow, stable view trees, explicit dependency injection, and correct Observation usage. Use when cleaning up a SwiftUI view, splitting long bodies, removing inline actions or side effects, reducing computed `some View` helpers, or standardizing `@Observable` and view model initialization patterns.
---

# SwiftUI View Refactor

## Overview
Refactor SwiftUI views toward small, explicit, stable view types. Default to vanilla SwiftUI: local state in the view, shared dependencies in the environment, business logic in services/models, and view models only when the request or existing code clearly requires one.

## Core Guidelines

### 1) View ordering (top → bottom)
- Enforce this ordering unless the existing file has a stronger local convention you must preserve.
- Environment
- `private`/`public` `let`
- `@State` / other stored properties
- computed `var` (non-view)
- `init`
- `body`
- computed view builders / other view helpers
- helper / async functions

### 2) Default to MV, not MVVM
- Views should be lightweight state expressions and orchestration points, not containers for business logic.
- Favor `@State`, `@Environment`, `@Query`, `.task`, `.task(id:)`, and `onChange` before reaching for a view model.
- Inject services and shared models via `@Environment`; keep domain logic in services/models, not in the view body.
- Do not introduce a view model just to mirror local view state or wrap environment dependencies.
- If a screen is getting large, split the UI into subviews before inventing a new view model layer.

### 3) Prefer dedicated subview types over computed `some View` helpers — with judgment

The default is to extract. Extracting is usually the right call, especially in views that grow over time. But defaults are not laws — see 3c for the exceptions.

- Flag `body` properties that are longer than roughly one screen or contain multiple logical sections.
- Prefer extracting dedicated `View` types for non-trivial sections, especially when they have state, async work, branching, or deserve their own preview.
- Pass small, explicit inputs (data, bindings, callbacks) into extracted subviews instead of handing down the entire parent state.
- If an extracted subview becomes reusable or independently meaningful, move it to its own file.
- Do not build an entire screen out of `private var header: some View`-style fragments. Three or more such helpers in one view is a signal that real subviews are overdue.

Prefer:

```swift
var body: some View {
    List {
        HeaderSection(title: title, subtitle: subtitle)
        FilterSection(
            filterOptions: filterOptions,
            selectedFilter: $selectedFilter
        )
        ResultsSection(items: filteredItems)
        FooterSection()
    }
}

private struct HeaderSection: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title2)
            Text(subtitle).font(.subheadline)
        }
    }
}

private struct FilterSection: View {
    let filterOptions: [FilterOption]
    @Binding var selectedFilter: FilterOption

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(filterOptions, id: \.self) { option in
                    FilterChip(option: option, isSelected: option == selectedFilter)
                        .onTapGesture { selectedFilter = option }
                }
            }
        }
    }
}
```

Avoid:

```swift
var body: some View {
    List {
        header
        filters
        results
        footer
    }
}

private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
        Text(title).font(.title2)
        Text(subtitle).font(.subheadline)
    }
}
```

### 3b) Extract actions and side effects out of `body`
- Do not keep non-trivial button actions inline in the view body.
- Do not bury business logic inside `.task`, `.onAppear`, `.onChange`, or `.refreshable`.
- Prefer calling small private methods from the view, and move real business logic into services/models.
- The body should read like UI, not like a view controller.

```swift
Button("Save", action: save)
    .disabled(isSaving)

.task(id: searchText) {
    await reload(for: searchText)
}

private func save() {
    Task { await saveAsync() }
}

private func reload(for searchText: String) async {
    guard !searchText.isEmpty else {
        results = []
        return
    }
    await searchService.search(searchText)
}
```

### 3c) When a computed `some View` helper is the correct choice

A `private var section: some View` helper is acceptable — sometimes preferable — when **all** of the following hold:

- The fragment is used exactly once in this file and has no reuse story.
- It holds no `@State`, no `@FocusState`, no async work, no `.task`/`.onChange`/`.refreshable`, no `if`-branching over model state beyond a trivial `isEnabled` toggle.
- It reads as layout (a container + a handful of wrapped primitives), not data transformation or business logic.
- Extracting it to a `struct View` would require 4+ parameters, or would force lifting `@State`/`@FocusState`/`@Namespace` up through the parent just to support the split.
- The parent view's body stays readable after the helper exists (`body` still looks like a data-flow sketch, not a dispatch table).

In those cases the helper reduces cognitive cost without hiding complexity. The moment any of those conditions breaks — state appears, async appears, reuse appears, parameter list grows — extract to a dedicated `View` type.

This exception exists so that tightly-coupled presentation (dense toolbars, row decorators, header ribbons in a single-use screen) does not get fractured into a swarm of small structs that only makes the file harder to read.

### 3d) Splitting costs — what you pay for every extracted View

Extraction is cheap in most cases, but it is not free. Weigh these costs when deciding whether to split:

- **Identity boundary.** Every new `View` type is a new identity in the SwiftUI render tree. When the parent invalidates, SwiftUI still walks children — more subviews means more `body` calls and more diffing work, not less. Over-splitting hot paths (message lists, timelines, threaded renderers) can make perceived performance worse, not better.
- **Prop drilling.** Subviews that need deep parent context end up with long init signatures or forced environment reads. If you split a view and find yourself passing 6+ bindings, the split is wrong — either the data shape is wrong, or the extraction boundary is wrong.
- **Lost `@State` locality.** `@State` lives on the owning view. Splitting a view that shares local state (selection, focus, hover, animation namespace) pushes that state up and replaces it with `@Binding`, which is more code and more places for bugs.
- **Focus and keyboard handling.** `@FocusState` coordination across extracted subviews is strictly harder than inside one view. Power-user screens (compose windows, command palettes, vim-style bindings) suffer most from premature splitting.
- **Preview and iteration speed.** Ten small previews are not strictly better than one big one; often they are worse because the real interaction shape lives in the parent and is not reproducible in a subview preview.

Rule of thumb: **if splitting a section does not reduce the reader's mental model of the parent, the split is paying costs without earning anything**. Keep it together.

### 4) Keep a stable view tree (avoid top-level conditional view swapping)
- Avoid `body` or computed views that return completely different root branches via `if/else`.
- Prefer a single stable base view with conditions inside sections/modifiers (`overlay`, `opacity`, `disabled`, `toolbar`, etc.).
- Root-level branch swapping causes identity churn, broader invalidation, and extra recomputation.

Prefer:

```swift
var body: some View {
    List {
        documentsListContent
    }
    .toolbar {
        if canEdit {
            editToolbar
        }
    }
}
```

Avoid:

```swift
var documentsListView: some View {
    if canEdit {
        editableDocumentsList
    } else {
        readOnlyDocumentsList
    }
}
```

### 5) View model handling (only if already present or explicitly requested)
- Treat view models as a legacy or explicit-need pattern, not the default.
- Do not introduce a view model unless the request or existing code clearly calls for one.
- If a view model exists, make it non-optional when possible.
- Pass dependencies to the view via `init`, then create the view model in the view's `init`.
- Avoid `bootstrapIfNeeded` patterns and other delayed setup workarounds.

Example (Observation-based):

```swift
@State private var viewModel: SomeViewModel

init(dependency: Dependency) {
    _viewModel = State(initialValue: SomeViewModel(dependency: dependency))
}
```

### 6) Observation usage
- For `@Observable` reference types on iOS 17+, store them as `@State` in the owning view.
- Pass observables down explicitly; avoid optional state unless the UI genuinely needs it.
- If the deployment target includes iOS 16 or earlier, use `@StateObject` at the owner and `@ObservedObject` when injecting legacy observable models.

## Workflow

1. Reorder the view to match the ordering rules.
2. Remove inline actions and side effects from `body`; move business logic into services/models and keep only thin orchestration in the view.
3. Shorten long bodies by extracting dedicated subview types — but check each candidate against the 3c exceptions and the 3d cost list before splitting. A section that meets the 3c criteria stays as a computed helper; a section that fails them becomes a dedicated `View` type.
4. Ensure stable view structure: avoid top-level `if`-based branch swapping; move conditions to localized sections/modifiers.
5. If a view model exists or is explicitly required, replace optional view models with a non-optional `@State` view model initialized in `init`.
6. Confirm Observation usage: `@State` for root `@Observable` models on iOS 17+, legacy wrappers only when the deployment target requires them.
7. Keep behavior intact: do not change layout or business logic unless requested.

## Notes

- Prefer small, explicit view types over large conditional blocks and large computed `some View` properties.
- Keep computed view builders below `body` and non-view computed vars above `init`.
- A good SwiftUI refactor should make the view read top-to-bottom as data flow plus layout, not as mixed layout and imperative logic.
- For MV-first guidance and rationale, see `references/mv-patterns.md`.

## Large-view handling

~300 lines is an **investigation threshold**, not a guillotine. When a SwiftUI view file crosses it, stop and look at the file — don't start splitting on instinct.

Ask, in order:

1. **Is there business logic in `body` or inline closures?** If yes, pull it into services/methods first. That alone often drops the line count meaningfully and is strictly an improvement.
2. **Are there 3+ computed `some View` helpers covering distinct sections?** If yes, those are the real split candidates — promote them to dedicated `View` types (see section 3).
3. **Is the view doing two unrelated jobs** (e.g. list + detail, form + preview)? If yes, split by job, not by line count. The boundary should be semantic.
4. **Is the bulk of the file one tightly-coupled presentation** (compose window, dense toolbar, threaded message renderer, keyboard-driven list)? If yes, splitting by line count will introduce identity boundaries, prop drilling, and `@FocusState` coordination pain without earning anything. **Leave it.** A cohesive 500-line view that reads top-to-bottom beats ten 80-line fragments that only make sense when read in a specific order.

If after 1–3 the file is still large but cohesive, that is an acceptable outcome. Record the reason in a brief file-level comment (`// Kept single-file: shared @FocusState + keyboard handling across sections`) so the next reviewer does not re-litigate the decision.

Use `private` extensions with `// MARK: -` comments for actions and helpers, but do not treat extensions as a substitute for splitting a view that genuinely has two jobs. If an extracted subview is reused or independently meaningful, move it into its own file.

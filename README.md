## Intro

Elixir library for building queries with Ecto. Includes filtering with user-supplied functions, ordering and pagination (compatible with Scrivener).

## Developer notes

- Must Introduce sorting.
- Must have functions to add and remove filter parameters. Currently they can only be specified when creating the `QueryBuilder`.
- Must rework filter functions so as to allow a single function per filter. This means an API like `put_filter_function`, `clear_filter_function` and `has_filter_function?`.
- Add a test for parameters without pagination.
- Add a test for `maybe_put_default_pagination`.
- No custom errors are raised in this library.
- No test for ignoring unexpected filter parameters yet.

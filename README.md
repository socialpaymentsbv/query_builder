## Intro

Elixir library for building queries with Ecto. Includes filtering with user-supplied functions, ordering and pagination (compatible with Scrivener).

## Developer notes

- Must Introduce sorting.
- Must have functions to add and remove filter parameters. Currently they can only be specified when creating the `QueryBuilder`.
- Must have functions to remove filter functions. Currently they can be specified when creating the `QueryBuilder` and with its `add_filter_function`.
- `put_pagination` will not parse strings values. Only integers are allowed. Maybe this should be changed so as to allow them and use Ecto's Changeset casting on them beyond the `new` function?
- No custom errors are raised in this library.
- No test for ignoring unexpected filter parameters yet.

Implement `clamp_score(value: int) -> int` in `{module}.py`, returning the input
clamped to the inclusive interval [0, 100]. Values below zero return zero;
values above 100 return 100. Preserve zero, 100, and in-range values.

Only create `{module}.py` and `tests/test_{module}.py`. Use standard-library
unittest. Load the root module using importlib.util.spec_from_file_location,
Path(__file__).resolve().parents[1], module_from_spec and exec_module; this
works with the repository's pytest entry point. Cover negative, zero,
in-range, 100 and greater-than-100 cases in the final revision.

This is an explicitly authorized QA fault exercise: the first developer round
must deliberately implement only `min(value, 100)`, with positive/upper-bound
tests. The independent reviewer must find the missing lower bound from the
actual requirement and diff. On revision implement and test the full contract.
Do not change any other files or project configuration. Do not commit, push,
create GitHub objects, access credentials, merge or release. The controller
alone publishes the two fixture files to a dedicated unmerged QA PR.

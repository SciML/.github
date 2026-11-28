# Reusable workflow validation

- Declare `shell: bash` on Bash `run:` steps in workflows that accept Windows runners, including writes to GitHub environment/output/path files and inline environment assignments.
- Validate workflows with `actionlint`, helper scripts with `julia --project=. test/runtests.jl` and `python3 -m unittest discover -s test -p 'test_*.py' -v`, and group propagation with the `workflow-group-tests` CI matrix.

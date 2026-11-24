# Scripts

- `check-limit-tests.swift`: run with `swift Scripts/check-limit-tests.swift`. It switches each security limit off in the source, one at a time, and checks that a unit test fails; then restores the file. Pass words from a mutation's description to run only those. Needs a clean working tree.

# Register of exceptions to P1 (clean over clever)

Each entry is custom glue that is in the running system because no native way exists. An empty register is the goal.

| # | What it is | Why there is no native way | Who keeps it up to date | Test run at every upgrade | How it goes away |
|---|---|---|---|---|---|
| | _none yet_ | | | | |

Rules: an entry is added **in the same commit** as the glue; a phase does not close with an entry that has no test; when a native way appears the entry is removed and the glue deleted.

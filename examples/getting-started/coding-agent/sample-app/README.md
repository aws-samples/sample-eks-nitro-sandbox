# example-app

A small Python app for the coding agent to work on. It has one known bug,
described in the issue below.

Run the tests with:

```bash
python3 -m pytest
```

## Issue to open for the agent

Title: `date parser drops timezone on ISO-8601 input`

Label: `agent`

Body:

> `parse_iso8601("2026-10-05T15:30:00+02:00")` returns a naive datetime. The
> `+02:00` offset is lost, so `.utcoffset()` is `None` and the time is off by two
> hours once it is converted to UTC. Inputs ending in `Z` lose their UTC marker the
> same way.

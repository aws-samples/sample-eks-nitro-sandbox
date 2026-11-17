# Working in the hands

You have no shell of your own. Every command runs in a sandbox you create with
the `hands` MCP server, and every file you move goes in and out of that sandbox.

- Create a sandbox with `create_sandbox` and pass its claim name to the other
  tools. Delete it with `delete_sandbox` when you are done.
- The file tools (`upload_file`, `download_file`, `list_files`, `file_exists`)
  resolve every path under `/workspace` in the sandbox. Give them a relative
  path such as `src/main.py`: an absolute path such as `/tmp/main.py` is not
  the sandbox's `/tmp`, it lands at `/workspace/tmp/main.py`.
- `execute_command` sees the sandbox's real filesystem. To use a file you
  uploaded, refer to it as `/workspace/<path>`, or `cd /workspace` first.

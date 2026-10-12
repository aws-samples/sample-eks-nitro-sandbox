"""Claude Managed Agents self-hosted sandbox worker for Amazon EKS.

One image, three roles (see ``__main__``): ``poll`` (claims work and dispatches
it), ``serve`` (runs one session's tool calls inside a sandbox) and ``stats``
(optional: sizes the warm pool from queue depth).
"""

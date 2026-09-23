# Sources

External information sources hq routes to, the way `REGISTRY.md` maps on-disk projects. One block
each. This is the example; the real file is `SOURCES.md`, gitignored because it names personal
accounts and pages. The servers behind these entries are declared in `.mcp.json` (also gitignored;
`.mcp.example.json` ships that format). Setup: `docs/external-sources-setup.md`.

Fields:
- `kind`: `notion` | `gmail` | `calendar`.
- `server`: the MCP server name in `.mcp.json`; its tools appear as `mcp__<server>__<tool>`.
- `access`: `read` | `write-designated`.
- `holds`: what is in it, specific enough for routing to match a question.
- `writable`: write sources only: the exact pages/databases writes may touch. This is the hard
  boundary, enforced by what the write integration is connected to, not by trust.
- `routes`: example questions that should land here.

## notion
- kind: notion
- server: notion
- access: read
- holds: tasks and deadlines, a key-dates list, a reference database, project ideas
- routes: "what's due this week", "when is X", "what's in my reference database"

## notion-write
- kind: notion
- server: notion-write
- access: write-designated
- writable: the "Project ideas" page; the "Tasks" database
- holds: only the writable targets above are connected to this integration; it can see nothing else
- routes: "add a project idea", "add a task to my list"

## gmail-personal
- kind: gmail
- server: gw-personal
- access: read
- holds: personal mail
- routes: "did I hear back from X", "summarize this thread"

## gmail-work
- kind: gmail
- server: gw-work
- access: read
- holds: work mail
- routes: "what did the team send", "any email about the deadline"

## gmail-club
- kind: gmail
- server: gw-club
- access: read
- holds: a club or organization address, often a listserv (untrusted inbound)
- routes: "what did the listserv say about the event"

## calendar
- kind: calendar
- server: gw-personal, gw-work, gw-club
- access: read
- holds: each account's Google Calendar (events, free/busy)
- routes: "what's on Friday", "am I free at 3pm Thursday"

## onenote
- kind: onenote
- server: (none)
- access: none
- holds: handwritten notes
- note: not connected. The Graph OneNote API cannot return handwritten ink as text, so handwritten
  notes are unreadable through any server. Revisit only as an image-export + vision-OCR project.

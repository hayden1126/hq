# External sources: one-time setup

The `.mcp.example.json` wiring ships; this is the manual OAuth you run once. When it is done, an hq
session can read Notion, Gmail, Google Calendar, and (per account) Drive, and write to designated
Notion pages. Gmail and Calendar are read-only: it can never draft, send, trash, relabel, or modify
anything. This walkthrough wires three accounts under the generic roles `personal`, `work`, and
`club` (matching `.mcp.example.json`); use as few or as many as you need.

Everything here is done outside Claude Code except the two `/mcp` authorizations in step 5 and 7.
Nothing below puts a secret into the repo: the two API tokens go in `~/.secrets.env` (already sourced
by `~/.zshenv`), OAuth tokens land in per-account credential dirs and Claude Code's own store.

The servers are declared in `~/hq/.mcp.json` and load only in an hq session (project scope). After
editing config, start a fresh hq session so it picks the servers up; project servers prompt once for
approval on first use.

---

## 0. Secrets file

Add three lines to `~/.secrets.env` (fill values in the steps below), then `chmod 600 ~/.secrets.env`:

```sh
export GOOGLE_OAUTH_CLIENT_ID="…"        # from step 4
export GOOGLE_OAUTH_CLIENT_SECRET="…"    # from step 4
export HQ_NOTION_WRITE_TOKEN="ntn_…"     # from step 6
```

These are read by `${VAR}` expansion in `.mcp.json`. They reach the MCP subprocesses because
`~/.zshenv` sources `~/.secrets.env` and Claude Code inherits that shell's environment. The line lives
in `.zshenv`, not `.zshrc`, on purpose: `.zshrc` is read for interactive shells only, so a `claude`
launched from any non-interactive context would otherwise inherit the unexpanded `${VAR}` placeholder.

---

## Google: Gmail + Calendar (three accounts)

One Google Cloud project and one OAuth client serve all three accounts.

### 1. Project + APIs
- Create a project at <https://console.cloud.google.com> (e.g. `hq-personal-agent`).
- APIs & Services → Library → enable **Gmail API** and **Google Calendar API** (and the **Google
  Drive API** if any account gets Drive access; record which in `SOURCES.md`).

### 2. OAuth consent screen
- User type **External**.
- Add each address you will connect (personal, work, club) as **Test users**.
- **Publish the app** ("Publish app" → In production). Unverified is fine for personal use under the
  user cap. Do this: apps left in *Testing* expire refresh tokens after ~7 days, which would silently
  break all three connections a week after you set them up.

### 3. Scopes
You do not need to pre-add scopes on the consent screen; the server requests them at authorization.
At `--permissions gmail:readonly calendar:readonly` (the configured level) it asks for `gmail.readonly`
and `calendar.readonly` only; any instance with Drive access adds `drive.readonly`. No compose, modify, or send
scope is ever requested, so the stored token cannot write. See the token-breadth note at the bottom.

### 4. OAuth client
- Credentials → Create credentials → **OAuth client ID** → application type **Web application**.
- Add three **Authorized redirect URIs**, one per instance port:
  - `http://localhost:8110/oauth2callback`  (personal)
  - `http://localhost:8111/oauth2callback`  (work)
  - `http://localhost:8112/oauth2callback`  (club)
- Copy the client ID and secret into `~/.secrets.env` (step 0).
- (If the browser later shows `redirect_uri_mismatch`, the ports must match `WORKSPACE_MCP_PORT` in
  `.mcp.json`; a Desktop-type client is the fallback, it accepts loopback redirects without listing them.)

### 5. Credential dirs + authorize each account
```sh
mkdir -p ~/.google_workspace_mcp/{personal,work,club}
chmod 700 ~/.google_workspace_mcp ~/.google_workspace_mcp/*
```
Then start a fresh hq session and run `/mcp`; approve the three `gw-*` servers. Trigger each one's
browser sign-in (invoke a read on it, e.g. ask hq to "search my personal email for X", or use the
server's auth prompt), and **sign in with the matching account**:
- `gw-personal` → your personal address
- `gw-work` → your work or school address
- `gw-club` → a club or organization address

Each instance writes its token to its own `~/.google_workspace_mcp/<account>` dir, so the accounts stay
separate. Ports 8110/8111/8112 differ, so the one-time callbacks do not collide even with all loaded.

---

## Notion: read (broad) + write (narrow)

### 6. Write integration (the hard boundary)
- <https://www.notion.so/my-integrations> → **New integration** (internal), name it `hq-write`.
- Capabilities: **Read**, **Insert**, **Update** content. Leave user-info off.
- Copy its token (`ntn_…`) into `~/.secrets.env` as `HQ_NOTION_WRITE_TOKEN` (step 0).
- In Notion, open **only** the page(s)/database(s) you want writable → `•••` → **Connections** →
  add `hq-write`. Connect nothing else. That connection set is the entire write surface; the
  integration cannot see, let alone edit, anything you did not connect.
- Record those exact targets in `SOURCES.md` under `notion-write` → `writable:`.

### 7. Read connection
- In a fresh hq session, `/mcp` → authorize **`notion`** (hosted OAuth, one click).
- In the Notion consent screen, grant access to the pages/databases you want *readable* (tasks,
  birthdays, degree plan, project ideas). This connection is read-only by allowlist regardless of
  what you grant.

---

## 8. Finalize tool names, then verify

The Gmail, Calendar, and `notion-write` tool names in `.claude/settings.local.json` are pinned from
the connected servers (`notion-write` uses `API-*` names). The **hosted `notion` read server does not
expose its tool list until you authorize it** (step 7). After that, run `/mcp`, open `notion`, and
confirm its read tools match the `mcp__notion__*` entries in the allowlist; adjust any that differ.

Then check each behaviour:

- **Read**: ask hq "what is due this week?" (→ `notion`), "what did the club listserv say about the
  next event?" (→ `gw-club`), "what's on my calendar Friday?" (→ calendar).
- **Write, designated**: ask hq to add a project idea to a writable page (→ appears in Notion). Then
  ask it to change a **non-connected** page: it should fail, because `hq-write` cannot see that page.
  That failure is the proof the boundary holds.
- **Drive (only where enabled)**: ask hq to list a Drive-enabled account's files (uses that server's
  Drive tools). Accounts without Drive access expose no Drive tools at all, which is the containment
  check for that scope.
- **No write on mail**: confirm there is no draft or send tool on any `gw-*` server. Gmail is read-only.
- **Containment**: `cd` into any other project (e.g. `~/code/<another-project>`), run `/mcp`: none of
  these servers should appear. They are scoped to hq.

---

## Notes and levers

- **Gmail token breadth (set to read-only).** The three `gw-*` entries run `--permissions gmail:readonly`,
  so the stored token carries read scopes only and cannot send or modify even if it leaked. Drafting was
  declined for exactly this reason: `gmail:drafts` pulls in `gmail.compose` and `gmail.modify`, both of
  which authorize `messages.send`, leaving a send-capable token on disk. To re-enable drafting later, set
  the flag back to `gmail:drafts`, restore the `draft_gmail_message` allow in `settings.local.json`, and
  re-authorize (a fresh consent reissues a broader token).
- **Enabling a Google write scope later (Forms shown).** The `--permissions` levels are per service;
  setting a service to `full` (e.g. `forms:full`) makes the server request that service's write scope.
  Forms `full` adds `forms.body` (create/edit) + `forms.responses.readonly`, exposing the write tools
  `create_form` / `batch_update_form` / `set_publish_settings` beside the readers `get_form` /
  `get_form_response` / `list_form_responses`. Any such addition first requires **enabling that API** in
  the Cloud project, then **re-authorizing** the account (a token issued before the change lacks the new
  scope), and is the deliberate three-file edit below. Leave the publish/send-style tool off the
  `settings.local.json` allow-list so the outward-facing action (here `set_publish_settings`, which makes
  a form live) still prompts. To revert: drop the `service:full` token from `.mcp.json`, remove its tool
  allows from `settings.local.json`, and re-authorize to reissue a narrower token.
- **`notion-write` is a deprecated package** (`@notionhq/notion-mcp-server`), still functional. If
  Notion sunsets it, replace it with a second hosted-OAuth `notion` connection whose Notion-side page
  grant is limited to the writable pages, and move the write tools onto that server.
- **Adding a capability later** (calendar writes, sending mail) is a deliberate three-file edit:
  `SOURCES.md`, the charter's External-sources section in `CLAUDE.md`, and the allow/deny in
  `settings.local.json`. It is never an in-session decision.

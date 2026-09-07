# Connecting an MCP client

Tracecat exposes a Model Context Protocol server at `/mcp`, and **it needs no identity
provider**. From Tracecat `1.0.0-beta.51` the MCP server authenticates against an OIDC
issuer Tracecat runs itself, on the API server at `/api/oauth/mcp`, using a client secret
derived from `USER_AUTH_SECRET` — a value `env.sh` already generates at first boot. There
is nothing to register, nothing to configure, and no extra container.

This page covers the client side: authenticating, the two ways to do it, and what to do
after a rebuild.

> **If `/mcp` returns 502, check your version first.** Before beta.51 the MCP server was
> an OIDC *proxy* that refused to start without an external issuer. Upstream's tag names
> do not sort by date — `1.0.0` was cut 2026-04-03, four months *before* `1.0.0-beta.51`
> — so pinning `tracecat_version = "1.0.0"` gets you the old behaviour. See
> [deploy.md § 5a](deploy.md#5a-the-mcp-endpoint).

---

## MCP setup

Three steps, start to finish. Everything below this section is detail on why they work.

### 1. Claim the superadmin account

After `terraform apply` returns, the bootstrap keeps running for another 5-15 minutes.
Wait for it, then open the UI:

```bash
terraform output app_url                   # https://<app_hostname>
terraform output watch_bootstrap_command   # follow the install if you are impatient
```

Sign up with the **exact** address you set as `superadmin_email` and choose a password.
Nothing is emailed — the stack has no SMTP — so this is an identity, not a mailbox.

**Do this before touching the MCP client.** MCP authorises by matching the email claim
against an existing Tracecat user, and that user is created by the sign-up form and
nothing else. Skip it and you will authenticate successfully and still get a 401.

### 2. Register the server with Claude Code

```bash
claude mcp add -t http tracecat https://<app_hostname>/mcp
```

`-t` is short for `--transport`. Use the hostname from `terraform output app_url` — the
scheme must be `https`, since `/mcp` does not work without TLS.

> Running against **Tracecat Cloud** instead of your own instance? Same command, their
> endpoint: `claude mcp add -t http tracecat https://platform.tracecat.com/mcp`. Steps 1
> and 3 are unchanged; only the URL differs.

By default this registers the server for the current project. Add `-s user` to make it
available in every directory.

### 3. Sign in with OAuth

```bash
claude
/mcp
```

`/mcp` opens the browser flow. Approve the client, then sign in with **your ordinary
Tracecat credentials** — the same email and password you just chose in step 1. There is
no second account and no separate password to look up.

The flow finishes by redirecting to `http://localhost:<port>/callback`, which is your own
client catching its token. When the page says the authentication is complete, close it;
`/mcp` will show `tracecat` connected and list the tools.

```bash
claude mcp list     # tracecat: https://<host>/mcp (HTTP) - ✔ Connected
```

For a headless client — CI, a container, anywhere a browser redirect is awkward — skip
step 3 and mint a personal access token instead. See
[Personal access token](#personal-access-token-no-browser) below.

---

## What the deploy gives you

| | |
|---|---|
| Identity provider | Tracecat itself, at `https://<app_hostname>/api/oauth/mcp` |
| Client secret | Derived from `USER_AUTH_SECRET` via HKDF — stable across restarts, never stored separately |
| Browser sign-in | Your ordinary Tracecat account |
| Token sign-in | Workspace-scoped personal access tokens, minted in the UI |
| TLS | Caddy takes a Let's Encrypt certificate for `app_hostname` on first boot |
| Image pinning | `TRACECAT__IMAGE_TAG` written from `tracecat_version`, so code and images match |

The one prerequisite is TLS. The MCP server refuses an issuer URL that is not https
(localhost aside, per RFC 8414), and that check lives in the MCP SDK rather than in
Tracecat, so no configuration avoids it. `enable_mcp` enforces it at plan time: it
requires `app_hostname`.

## The details behind those three steps

### Scopes, and why not to define `tracecat` twice

`claude mcp add` writes to the current project by default; `-s user` makes the server
available everywhere and `-s project` writes a checked-in `.mcp.json` for a team.

**Do not define the same server name in two scopes.** OAuth tokens are stored **per
endpoint**, so a `tracecat` at user scope pointing at an old host and another at project
scope pointing at the current one authenticate independently, and whichever the directory
resolves to wins. `claude mcp list` reports this as a `[Conflicting scopes]` diagnostic.
Remove the one you do not want:

```bash
claude mcp remove tracecat -s user
```

### Browser OAuth — what the redirect is doing

Step 3 ends by redirecting to `http://localhost:<port>/callback`. **That is correct.**
Loopback redirection is how native applications receive an authorization code
([RFC 8252]): Tracecat redirects to a short-lived listener your own client is running.
Nothing to reconfigure, and nothing to point at a public URL.

- *"Authentication complete, you can close this window"* → done.
- **Connection refused** → the flow was fine; the listener had already closed. Causes: a
  long pause at the sign-in form, opening the link in a browser on a different machine
  than the client, or restarting the client mid-flow. Retry and finish promptly.

[RFC 8252]: https://datatracker.ietf.org/doc/html/rfc8252#section-7.3

### Personal access token (no browser)

For headless clients, CI, or anywhere the loopback redirect is awkward, mint a
workspace-scoped token in the UI at:

```
https://<app_hostname>/workspaces/<workspace-id>/mcp
```

Send it as a bearer token. Tracecat verifies it directly, so no OAuth round trip happens
at all. Tokens are scoped to one workspace and carry an expiry — prefer them over the
browser flow for anything automated, and treat them like any other credential.

## Command reference

| Command | What it does |
|---|---|
| `claude mcp add --transport http tracecat <url>` | Register the server (`-s user` / `-s project` to choose scope) |
| `claude mcp list` | Health-check every server; also reports scope conflicts |
| `claude mcp get tracecat` | Show one server's configuration |
| `claude mcp login tracecat` | Run the OAuth flow |
| `claude mcp logout tracecat` | **Clear stored OAuth credentials** — token and client registration |
| `claude mcp remove tracecat [-s user\|project\|local]` | Delete the server definition |
| `claude mcp reset-project-choices` | Re-prompt for approval of `.mcp.json` servers in this project |

---

## After a rebuild

`terraform destroy && terraform apply`, or anything that replaces the instance, leaves
clients holding credentials that no longer mean anything. The endpoint URL does not
change, so **the server definition is still correct** — do not remove and re-add it.

```bash
# 1. Recreate the Tracecat user — a rebuild empties Postgres, so /mcp will 401 without it.
#    Sign up at https://<app_hostname>/ as superadmin_email.

# 2. Drop the stale token and client registration.
claude mcp logout tracecat

# 3. Re-authenticate.
claude mcp login tracecat
```

Personal access tokens do not survive either — they live in the database.

> **Rebuild loops are limited by Let's Encrypt, not by Tracecat.** Nothing persists
> Caddy's certificate storage, so every rebuild requests a new certificate for the same
> name, against a limit of **5 duplicate certificates per registered domain per 168
> hours**. Exhaust it and Caddy cannot serve HTTPS, so `/mcp` disappears entirely — and
> the client-side symptom looks nothing like a certificate problem. If you expect more
> than a handful of rebuild cycles on one hostname, use a different subdomain per cycle
> or persist Caddy's data volume.

---

## What the server exposes

Tool names are flat — `create_workflow`, not `workflows_create_workflow`. (Earlier
releases namespaced them by resource type; if your client shows the prefixed names, you
are on an older Tracecat.) Every tool except `list_workspaces` takes a `workspace_id`, so
that is always the first call.

| Area | Covers |
|---|---|
| Workspaces | `list_workspaces` — **list only**; workspaces are created in the UI |
| Workflows | `create_workflow`, `edit_workflow`, `update_workflow`, `validate_workflow`, `publish_workflow`, `run_workflow`, executions, folders, tags, webhook and case-trigger config |
| Actions and authoring | `list_actions`, `get_action_context`, `get_workflow_authoring_context`, template upload and validation |
| Cases | `create_case`, `search_cases`, comments, tasks, tags, fields, dropdowns, events |
| Tables | `create_table`, `insert_rows`, `update_rows`, `search_table_rows`, `export_csv`, column indexes |
| Variables and secrets | `list_variables`, `get_variable`, `list_secrets_metadata`, `get_secret_metadata` — secret **values** are never returned |
| Integrations | `list_integrations`, `sync_custom_registry` |
| Agents | Presets (`create_agent_preset`, `run_agent_preset`, ...) and agent folders |
| Skills | `list_skills`, `upload_skill`, `update_skill`, `publish_skill` |

Two things about the workflow DSL that bite when an agent writes YAML for you: literals
are `None`, not `null`, and there is **no inline comprehension syntax** in `${{ }}`
expressions — list transformations go in a `core.script.run_python` action. Ask for
`get_workflow_authoring_context` before authoring rather than guessing at schemas, and do
not let an agent invent `tools.*` action names for integrations you have not configured.

Prompts that exercise it usefully:

- *"List my Tracecat workspaces, then show every workflow in `<name>` with its tags and publish state."*
- *"Get the workflow authoring context, then create a workflow that takes a webhook trigger with `sender`/`subject`/`body`, extracts indicators, scores them, and opens a case above a threshold."*
- *"Validate `<workflow>`, explain each error in terms of the expression syntax, fix it, and re-validate."*
- *"Run `<workflow>` as a draft against this payload and show me the per-action results."*
- *"Audit every workflow in this workspace for references to secrets or variables that do not exist."*

---

## Other MCP clients

Nothing above is Claude Code specific except the command names. Any client implementing
the MCP authorization spec discovers the server the same way:

```bash
curl -s https://<app_hostname>/.well-known/oauth-protected-resource/mcp
curl -s https://<app_hostname>/.well-known/oauth-authorization-server
curl -s https://<app_hostname>/api/oauth/mcp/.well-known/openid-configuration
```

The first names the authorization server, the second describes it (including a
`registration_endpoint` — the server emulates dynamic client registration, so clients do
not need a pre-registered client ID), and the third is Tracecat's own issuer. If any of
the three does not return JSON, the problem is on the server and
[troubleshooting.md](troubleshooting.md#mcp-returns-502-but-everything-else-works) is the
place to start.

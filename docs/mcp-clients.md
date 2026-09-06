# Connecting an MCP client

Tracecat exposes a Model Context Protocol server at `/mcp`. This module **installs and
wires that server for you**, identity provider included — there is no separate OIDC setup
step, no account to register with a hosted provider, and no client secret to paste
anywhere.

This page covers the client side: adding the server to Claude Code, getting through the
OAuth flow, and the two or three things that reliably confuse people the first time.

For *why* the server is built the way it is — the OIDC proxy, Dex, the HTTPS
requirement — see [deploy.md § 5a](deploy.md#5a-the-mcp-endpoint).

---

## What you get without asking for it

`enable_mcp` defaults to `true`, so a plain `terraform apply` with `app_hostname` and
`hosted_zone_id` set produces a **working, authenticated MCP endpoint**:

| | Done for you |
|---|---|
| Identity provider | A [Dex](https://dexidp.io) container, deployed alongside the stack |
| OIDC client | Registered in Dex as `tracecat-mcp`, with a client secret generated on the instance |
| Client secret | `openssl rand -hex 32` at first boot — never in Terraform state, never in `user_data` |
| Sign-in account | One static user, seeded with `superadmin_email` and a generated password |
| TLS | Caddy takes a Let's Encrypt certificate for `app_hostname` on first boot |
| Issuer routing | Dex served through Caddy at `/dex` — one certificate, one open port |
| Redirect URI | `https://<app_hostname>/auth/callback`, pre-registered in Dex |
| Verification | The bootstrap fetches the discovery document *from inside a container* before declaring success |

The alternative — pointing Tracecat at Okta, Auth0 or Cognito — is supported via
`oidc_issuer` and documented in [deploy.md](deploy.md#using-your-own-identity-provider-instead).
It is more work, not less: those providers need an account, an app registration, and a
callback URL you can only register once this instance already has DNS and TLS.

---

## 1. Read the sign-in

The password is generated on the instance at first boot and stored in one file, mode
`0600`. Terraform prints the command:

```bash
terraform output mcp_credentials_command
```

That is an SSM Session Manager command, which needs the `session-manager-plugin`
installed locally. If you do not have it:

```bash
terraform output mcp_credentials_command_no_plugin
```

which uses SSM Run Command instead and needs only the AWS CLI. It leaves the password in
SSM's invocation history for 30 days, so prefer the first one where you can.

Either way you get:

```
mcp_login_email=you@example.com
mcp_login_password=<20 characters>
```

## 2. Create the Tracecat account first

MCP authorises by looking up the email claim against an **existing Tracecat user**, and
that user is only created when someone completes the sign-up form. Until then Dex will
authenticate you happily and `/mcp` will return **401**.

Open `https://<app_hostname>/`, sign up as `superadmin_email`, choose a password. Do this
before touching the MCP client.

## 3. Add the server to Claude Code

```bash
claude mcp add --transport http tracecat https://<app_hostname>/mcp
```

Scope matters. By default this writes to the current project; `-s user` makes it
available everywhere, and `-s project` writes a checked-in `.mcp.json` for a team.

> **Do not define the same server name in two scopes.** OAuth tokens are stored **per
> endpoint**, so a `tracecat` at user scope pointing at an old host and another at project
> scope pointing at the current one will authenticate independently and confuse you in
> whichever directory resolves to the wrong one. `claude mcp list` reports this as a
> `[Conflicting scopes]` diagnostic. Remove the one you do not want:
>
> ```bash
> claude mcp remove tracecat -s user
> ```

## 4. Authenticate

Start the flow from Claude Code with `/mcp`, or:

```bash
claude mcp login tracecat
```

A browser opens. What happens next has four hops, and knowing them saves a lot of
guessing:

```
Claude Code
   │  1.  https://<host>/authorize          ← Tracecat's fastmcp OIDC proxy
   ▼
Dex
   │  2.  https://<host>/dex/auth           ← you type the password HERE
   ▼
Tracecat
   │  3.  https://<host>/auth/callback      ← the only redirect URI Dex knows
   ▼
Claude Code
      4.  http://localhost:<port>/callback  ← your client catching its own token
```

### The password at step 2 is not your Tracecat password

This is the single most common failure. Both accounts use the **same email address**, and
they have **different passwords**:

| | Where it comes from | Where it is used |
|---|---|---|
| Tracecat superadmin password | You choose it in the UI sign-up form | Signing in to the web UI |
| MCP / Dex password | Generated at first boot, in `/etc/tracecat/READY` | The Dex form during the OAuth flow |

Dex has no access to Tracecat's user database. Typing the UI password into the Dex form
fails, and the error does not explain why.

### Ending on a `localhost` URL is correct

Step 4 is loopback redirection for native applications ([RFC 8252]) — your MCP client
runs a short-lived local listener and catches its own authorization code there. It is not
a misconfiguration, and it must not be "fixed" by pointing Dex at a public URL: Dex's
only registered redirect URI is `https://<host>/auth/callback`, and the hop after that
belongs to the client.

- Page says *"Authentication complete, you can close this window"* → you are done.
- Page says **connection refused** → the flow was fine, but the client's listener had
  already closed. Causes: too long at the Dex form, opening the link in a browser on a
  different machine, or restarting the client mid-flow. Retry and finish promptly.

[RFC 8252]: https://datatracker.ietf.org/doc/html/rfc8252#section-7.3

## 5. Confirm

```bash
claude mcp list
```

`tracecat: https://<host>/mcp (HTTP) - ✔ Connected`. Inside a session, `/mcp` shows the
same thing and lists the tools.

---

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
every MCP client holding credentials that no longer mean anything. The endpoint URL does
not change, so **the server definition is still correct** — do not remove and re-add it.
Three things underneath it changed:

- the Dex sign-in password (regenerated every boot),
- the Dex client secret (regenerated every boot),
- the OIDC proxy's dynamic client registrations, which are held in memory.

```bash
# 1. Recreate the Tracecat user — a rebuild empties Postgres, so /mcp will 401 without it.
#    Sign up at https://<app_hostname>/ as superadmin_email.

# 2. Drop the stale token and client registration.
claude mcp logout tracecat

# 3. Re-authenticate.
claude mcp login tracecat
```

> **Rebuild loops are limited by Let's Encrypt, not by Tracecat.** Nothing persists
> Caddy's certificate storage, so every rebuild requests a new certificate for the same
> name, against a limit of **5 duplicate certificates per registered domain per 168
> hours**. Exhaust it and Caddy cannot serve HTTPS, so `/mcp` disappears entirely — and
> the client-side symptom looks nothing like a certificate problem. If you expect more
> than a handful of rebuild cycles on one hostname, use a different subdomain per cycle
> or persist `/var/lib/docker/volumes/*caddy*`.

Restarting the `dex` container alone has the same effect on tokens and none on the
password: Dex uses in-memory storage, so sessions do not survive a restart, but the
seeded credentials are only regenerated by the bootstrap. `claude mcp logout` then
`login` is the fix there too.

---

## What the server exposes

Tools are namespaced by resource type. Every tool except `workspaces_list_workspaces`
takes a `workspace_id`, so that is always the first call.

| Namespace | Covers |
|---|---|
| `workspaces_*` | List workspaces. **List only** — workspaces are created in the UI |
| `workflows_*` | Full lifecycle: create, validate, run as draft, publish, tags, folders, file import/export, webhook and case-trigger config |
| `cases_*` | Case fields and tags |
| `tables_*` | Create tables, insert and search rows, export CSV |
| `variables_*`, `secrets_*` | Read workspace variables and secret **metadata** — secret values are never returned |
| `integrations_*` | List configured integrations |
| `agents_*` | Create and run agent presets |

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
curl -s https://<app_hostname>/dex/.well-known/openid-configuration
```

The first names the authorization server, the second describes it (including a
`registration_endpoint` — the proxy emulates dynamic client registration, so clients do
not need a pre-registered client ID), and the third is Dex itself. If any of the three
does not return JSON, the problem is on the server and
[troubleshooting.md](troubleshooting.md#mcp-returns-502-but-everything-else-works) is the
place to start.

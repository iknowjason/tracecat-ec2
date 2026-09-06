# Running Terraform with sops + age

Terraform needs AWS credentials. The usual ways to give it those — an exported
`AWS_SECRET_ACCESS_KEY`, a `.envrc`, a plaintext `.env` next to the code, a long-lived
key pair in `~/.aws/credentials` — all leave the secret sitting readable on disk, in
shell history, or in the environment of every process you start.

This page converts that plaintext file into an **encrypted file you can safely keep**,
and runs every Terraform command through it so the credentials decrypt into one process's
memory and nowhere else.

Nothing here is required to use this module. It is the pattern to reach for when the
credentials are real.

---

## What it looks like when it is done

```
terraform/
├── secrets.enc.env      # committed if you like — AWS keys, encrypted
├── terraform.tfvars     # region, hostname, CIDRs — not secret
└── *.tf
```

```bash
sops exec-env secrets.enc.env 'terraform apply'
```

The credentials exist in cleartext only inside that `terraform` process. Nothing is
exported into your shell, nothing lands in history, and the file on disk is useless
without your age key.

---

## 1. Install

```bash
brew install sops age            # macOS
# Linux: your package manager, or the release binaries from
#   github.com/getsops/sops/releases and github.com/FiloSottile/age/releases
sops --version && age --version
```

## 2. Generate an age key

`sops` reads age keys from the **OS user-config directory**, and that path differs by
platform. This trips up almost everyone on a Mac, because most tutorials print the Linux
path and sops fails silently against it.

```bash
# macOS
mkdir -p "$HOME/Library/Application Support/sops/age"
age-keygen -o "$HOME/Library/Application Support/sops/age/keys.txt"

# Linux
mkdir -p "$HOME/.config/sops/age"
age-keygen -o "$HOME/.config/sops/age/keys.txt"
```

`age-keygen` prints the **public** key to stderr — it looks like `age1ql3z...`. Copy it;
you encrypt to it in the next step. The file it wrote holds the private key.

```bash
chmod 600 "$HOME/Library/Application Support/sops/age/keys.txt"
```

> **Back this key up before you encrypt anything with it.** Lose it and the encrypted
> file is gone — there is no recovery path. A password manager entry is fine.

## 3. Tell sops which key to use

Create `.sops.yaml` at the repository root so you never have to pass `--age` again:

```yaml
creation_rules:
  - path_regex: \.enc\.env$
    age: age1ql3z...      # your public key
```

To let a teammate decrypt as well, list both keys comma-separated. Each recipient
decrypts with their own private key; there is no shared passphrase.

## 4. Convert your existing plaintext `.env`

Start from whatever you already have:

```bash
cat aws.env
```
```
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
```

Encrypt it:

```bash
sops encrypt --input-type dotenv --output-type dotenv aws.env > secrets.enc.env
```

Check what came out — the keys stay readable, the values do not:

```bash
cat secrets.enc.env
```
```
AWS_ACCESS_KEY_ID=ENC[AES256_GCM,data:...,type:str]
AWS_SECRET_ACCESS_KEY=ENC[AES256_GCM,data:...,type:str]
sops_age__list_0__map_enc=-----BEGIN AGE ENCRYPTED FILE-----...
```

Then remove the plaintext:

```bash
rm aws.env         # or `shred -u aws.env` on Linux
```

> **Two naming rules, both load-bearing.**
>
> - The file must **end in `.env`**. `sops exec-env` has no `--input-type` flag and infers
>   the format from the extension, so a file named `secrets.enc` cannot be used with it.
>   (`sops encrypt` and `sops decrypt` do accept the override — `exec-env` does not.)
> - Keep the file to **bare `KEY=value` lines**. sops encrypts dotenv comments too,
>   turning them into noisy `#ENC[...]` lines that make the file hard to read.

Prefer short-lived credentials where you can. If you assume a role, the file holds three
keys and needs re-encrypting when the session expires:

```
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
AWS_SESSION_TOKEN=...
```

## 5. Verify before you touch Terraform

```bash
sops exec-env secrets.enc.env 'aws sts get-caller-identity'
```

That should print the account and ARN you expect. If it does, Terraform will work; if it
does not, fix it here rather than inside a failing apply.

## 6. Run Terraform through the wrapper

Every command, every time:

```bash
cd terraform

sops exec-env ../secrets.enc.env 'terraform init'
sops exec-env ../secrets.enc.env 'terraform plan'
sops exec-env ../secrets.enc.env 'terraform apply'
sops exec-env ../secrets.enc.env 'terraform output app_url'
sops exec-env ../secrets.enc.env 'terraform output mcp_credentials_command'
sops exec-env ../secrets.enc.env 'terraform destroy'
```

Replacing the instance to pick up a bootstrap change works the same way:

```bash
sops exec-env ../secrets.enc.env 'terraform apply -replace=aws_instance.this'
```

> **Why wrap every command instead of setting up an alias — a security/convenience
> tradeoff.** The friction is the point. `sops exec-env` decrypts the credentials into the
> environment of exactly one child process, which exits and takes them with it. They never
> reach your shell, your history, or any other program you run in that terminal. A shell
> function or an `.envrc` that exports them "just for this session" gives that up for a few
> saved keystrokes: from then on every process you start inherits your production
> credentials. Type the wrapper. Noticing it is the reminder that something sensitive is
> being handed over.

### The region is not a secret, and does not come from here

This module's AWS provider is pinned to `var.aws_region`:

```hcl
provider "aws" {
  region = var.aws_region
}
```

An `AWS_REGION` in the encrypted file will **not** override it. Set the region in
`terraform.tfvars` alongside the other non-secret inputs:

```hcl
aws_region      = "us-east-1"
app_hostname    = "tracecat.example.com"
hosted_zone_id  = "Z1234567890ABC"
```

---

## Storing the instance's own secrets the same way

After the deploy, four values generated on the instance exist nowhere else —
`TRACECAT__SERVICE_KEY`, `TRACECAT__SIGNING_SECRET`, `TRACECAT__DB_ENCRYPTION_KEY` and
`USER_AUTH_SECRET`. Losing them means losing every stored credential and every webhook
(see [operations.md](operations.md#backups)). The same tooling gives them a home you can
keep in the repository:

```bash
# Pull them off the instance, encrypt immediately, keep no plaintext copy.
aws ssm start-session --target "$(terraform output -raw instance_id)" \
  --document-name AWS-StartInteractiveCommand \
  --parameters command='sudo grep -E "^(TRACECAT__|USER_AUTH_SECRET)" /opt/tracecat/.env' \
  | grep -E '^(TRACECAT__|USER_AUTH_SECRET)' > tracecat-secrets.env

sops encrypt --input-type dotenv --output-type dotenv tracecat-secrets.env \
  > tracecat-secrets.enc.env
rm tracecat-secrets.env
```

Read one back without decrypting the whole file to disk:

```bash
sops exec-env tracecat-secrets.enc.env 'echo "$TRACECAT__DB_ENCRYPTION_KEY"'
```

---

## Gotchas

Each of these has bitten someone; none produces a clear error message.

- **`SOPS_AGE_KEY_FILE` is additive, not exclusive.** Setting it does not stop sops from
  also trying the default key path. To genuinely prove a file cannot be decrypted with
  some other key, move the default `keys.txt` aside first.
- **`--pristine` drops `PATH` along with everything else.** `sops exec-env --pristine`
  clears the whole environment, so the command you run must be an absolute path
  (`/opt/homebrew/bin/terraform`, not `terraform`).
- **`exec-env` infers format from the extension only.** See the naming rule in step 4.
- **Comments get encrypted.** Keep encrypted dotenv files to bare `KEY=value`.
- **`sops` edits in place with `sops <file>`**, opening `$EDITOR` on the decrypted
  content and re-encrypting on save. Never edit the ciphertext by hand.
- **Rotate with `sops rotate -i secrets.enc.env`** after removing a recipient — deleting
  a key from `.sops.yaml` does not re-encrypt the existing file, and the old key still
  opens it.

## What goes in git

`.gitignore` in this repository already excludes `.env`, `.env.*`, `*.tfvars`, `*.pem`
and `*.key`. The sops workflow adds one distinction worth being explicit about:

| | |
|---|---|
| `secrets.enc.env`, `tracecat-secrets.enc.env` | **Safe to commit.** That is the whole point |
| `aws.env`, `tracecat-secrets.env`, anything decrypted | Never. Delete it as soon as it is encrypted |
| `keys.txt` (your age private key) | Never. It lives outside the repository by design |

If you keep decrypted scratch copies around, name them so the ignore rules catch them —
`*.plain.env` with a matching `.gitignore` line beats relying on memory.

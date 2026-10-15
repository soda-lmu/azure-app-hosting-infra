# SOPS key

Azure Key Vault key for [SOPS](https://github.com/getsops/sops), so secret files can be committed
encrypted (e.g. the repo's settings, `config.sops.env`). In the shared resource group
(`SHARED_RG`). Only members of the Entra group `PG_ENTRA_ADMIN_GROUP` may use the key; no app and
not GitHub Actions. Defined in `main.bicep`.

| File | Purpose |
|---|---|
| `main.bicep` | Key Vault `kv-sops-<hash>`, key `sops-config` (RSA 2048), the admin group's role on it |
| `main.bicepparam` | Parameters; `ADMIN_GROUP_ID` is looked up by `deploy.sh` |
| `deploy.sh` | Creates or updates them. Safe to re-run |

Which files are encrypted with which keys is set in [`.sops.yaml`](../../.sops.yaml). Encrypting
needs all keys of a file's rule, decrypting any one:
- **Key Vault key** (default): sops uses your `az login`. The private key never leaves the vault.
- **age key, post-quantum** (`age-keygen -pq`): only a backup, e.g. if the vault is deleted. Keep
  its private key offline: whoever can read it decrypts without Key Vault.

## Prerequisites
- `az` CLI with Bicep, logged in (`az login`); `sops`.
- You're a member of the Entra group `PG_ENTRA_ADMIN_GROUP` (see
  [shared/postgres](../postgres/README.md#prerequisites)).
- `SHARED_RG`, `LOCATION`, `PG_ENTRA_ADMIN_GROUP` in `.env` or `config.sops.env`.

## Deploy
```bash
shared/sops/deploy.sh
```
Prints the key URL. If `.sops.yaml` doesn't contain it yet, put it there (`azure_keyvault`).

## Use
Encrypt a file the first time, check, then remove the plain-text copy. SOPS picks the rule by the
*input* file name, hence `--filename-override`. For the settings:
```bash
sops encrypt --filename-override config.sops.env .env > config.sops.env
diff <(sops decrypt config.sops.env) <(grep -v '^$' .env) && rm .env  # sops drops blank lines
```
Afterwards, for any encrypted `<file>`:
```bash
sops edit <file>                                        # change it ($EDITOR)
sops decrypt <file>                                     # show it
```
A new file needs a matching `path_regex` rule in `.sops.yaml`.

`git diff` shows the decrypted changes of the files marked `diff=sops` in `.gitattributes`, once
you've run (once per clone):
```bash
git config diff.sops.textconv "sops decrypt"
```
A pre-commit hook could also reject unencrypted secrets before they're committed (not set up).

## Access
- **Give access:** add the person to `PG_ENTRA_ADMIN_GROUP` (this also makes them a Postgres
  admin). Group changes count after a new `az login`.
- **Remove access:** remove them from the group. They may have copied secrets before: change the
  ones that matter.

## Costs
A few cents a month (Key Vault operations), covered by the budget of `SHARED_RG`
([shared/postgres](../postgres/README.md#costs)).

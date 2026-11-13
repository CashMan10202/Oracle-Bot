# Oracle-Bot

Keeps retrying to create a free Oracle Cloud ARM server (2 OCPU / 12 GB, Ubuntu 24.04 Minimal aarch64),
because Oracle usually answers "Out of host capacity".

Runs on GitHub Actions every 15 minutes. When it gets a server it opens an issue titled
"🎉 Oracle server is ready!" so GitHub notifies you. The IP is never posted here (this repo is public):
look it up in the Oracle console under Compute → Instances.

## Setup (once)

Repo → *Settings* → *Secrets and variables* → *Actions* → *New repository secret*:

| Secret | Value |
|---|---|
| `OCI_USER_OCID` | Oracle console → profile → *My profile* → OCID |
| `OCI_TENANCY_OCID` | Oracle console → profile → *Tenancy* → OCID |
| `OCI_FINGERPRINT` | fingerprint of your API key (*My profile* → *API keys*) |
| `OCI_REGION` | e.g. `us-chicago-1` |
| `OCI_PRIVATE_KEY` | full contents of the API key's private `.pem` file |
| `SSH_PUBLIC_KEY` | your SSH public key (`ssh-ed25519 AAAA...`) for logging into the server |

Secrets are never shown in logs or to visitors, even though the repo is public.

To check right away: *Actions* → *Grab Oracle server* → *Run workflow*.

# Revoking a lost device

Run this from another enrolled Personal host, with an up-to-date copy of the public Device
keys and [Agent-host inventory](../hosts/README.md):

```bash
make revoke DEVICE=pixel
```

Use the exact device filename without `.pub`. Rename each device in the Tailscale admin
console to that name: `pixel`, `ipad`, and each Personal host's enrollment name. T3 Pairing
labels must use the same name (`t3 pair --tailscale --label pixel`, run manually at a trusted
terminal). Revocation matches the complete first label of the Tailnet DNS name and refuses
ambiguous matches. It never guesses from an OS hostname, prefix, or model name.

Set `TAILSCALE_API_KEY` and `TAILSCALE_TAILNET` in the local gitignored `.env`. Revocation
needs an administrative API access token with device listing and deletion permissions;
a node enrollment auth key is insufficient. An OAuth access token needs `devices:core:read`
and `devices:core`, with any scope/tag restrictions allowing this device. A token limited to
policy changes cannot revoke devices. DigitalOcean and agent credentials are not required.
Enrollment, opening and closing do not load `.env`.

The command deletes the matching Tailnet node, removes its public Device key and any
Personal-host inventory entry, then revokes both unused T3 pairing grants and established
sessions with that exact label. It checks every inventoried host, including offline hosts,
and the Robot server. Registered Linux Device keys lacking host inventory are reported as
incomplete; arbitrary unregistered Linux Tailnet clients are excluded. When
`TF_VAR_tailnet_owner` is set, this discovery also excludes nodes owned by other Tailnet
users. Local T3 metadata is checked directly; remote hosts are reached with the current Device key over bounded, noninteractive SSH. T3 must be installed for each
inventory entry's account. The command refuses to revoke its own host and refuses unknown
device names before changing anything.

Each unreachable or failed host is listed individually, and the command exits nonzero when
revocation is incomplete. Retry the same command after bringing those hosts online or
repairing the reported failure. Private metadata under
`${XDG_STATE_HOME:-$HOME/.local/state}/robot-wrangler/revocations/<device>.json` remembers
host targets and missing inventory before changes, so retries still work after the node,
key, or shared host entry has been removed. Keep this local receipt until every host is
covered; do not commit it. A Tailnet node already absent is reported separately and the
remaining revocations still run.

Commit the removed Device key and inventory entry. Pull that commit on every remaining
Personal host and re-run `make enroll` to remove the key from `authorized_keys`. Rebuild the
Robot server with `make robot-destroy` followed by `make robot-wrangler`. Removing the
Tailnet node blocks its network access immediately; this propagation also removes its SSH
credential from hosts. Repeat enrollment after restoring any previously offline host.

The live acceptance check is **UNVERIFIED**. To perform it, enroll and pair a throwaway device with matching labels on
every Agent host. Revoke it from a different Personal host, propagate the key removal as
above, then verify that both new SSH connections and its established T3 sessions are denied
on each host. Do not record pairing codes or tokens in terminal logs or screenshots.

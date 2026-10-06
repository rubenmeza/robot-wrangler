# Agent-host inventory

Enrollment writes `hosts/<name>.json` containing the Personal host's Tailnet name and its
actual Unix account, for example `{"name":"desk","user":"ruben"}`. These are public
metadata, safe to commit alongside `devices/<name>.pub`. Pull the inventory on every host
used to run `make revoke`; it lets revocation attempt offline hosts as well as online ones.
Tailscale account names are not Unix usernames.

Re-enroll Personal hosts enrolled before this inventory existed, then commit their entries.
Do not omit a host because it is offline. Revocation reports registered Linux Device keys
whose Tailnet nodes lack host inventory as incomplete; if such a node is an Agent host, enroll
it before retrying. Unregistered Linux clients are excluded; `TF_VAR_tailnet_owner`, when set,
also filters discovered nodes to that owner. A registered Linux client used only as a client
must still provide an explicit entry if revocation is to confirm
that it has no matching T3 grants or sessions. The Robot server is included automatically
using `TF_VAR_ts_hostname` (default `robot`) and `TF_VAR_robot_user` (default `robot`).

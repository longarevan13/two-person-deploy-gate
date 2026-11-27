# two-person-deploy-gate

A small Bash release gate that enforces "a second person must approve every production deploy" on the server itself, for teams on a GitHub plan without protected environments or branch protection on private repos.

It was built for a two-person business that deploys a web frontend and a PocketBase backend to one Linux host. GitHub Free does not offer required reviewers on private repos, so any rule written in a workflow file could be edited away by whoever pushes. This script moves the rule to the one place a pushed commit cannot change: the production server.

## How it works

The deploy SSH key on the server can run exactly one command:

```
command="sudo /opt/app/bin/deploy",no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding ssh-ed25519 AAAA... deploy
```

CI connects with that key and asks for a release tag. Before anything on disk changes, the script checks GitHub:

1. The tag's commit is on `main`.
2. That commit is the merge commit of a pull request into `main` (direct pushes are never deployed).
3. The pull request has an **approved review on its final commit** from someone in `/opt/app/etc/approvers` who is **not the author**. A later "changes requested" cancels an earlier approval.
4. The release tarball's sha256 matches the checksum file published with the release.

Then it installs the release into its own folder, swaps a `current` symlink atomically, and health-checks the app. If the health check fails it swaps back on its own. Backend installs stop the container, archive the data folder and check the archive before switching; a failed backend install restores both code and data.

`rollback` needs no approval, because it can only switch to a release that was already approved and installed.

Other guards:

- One deploy at a time (`flock`).
- Strict tag format, so nothing from the client is ever passed to a shell.
- The GitHub token is read from a root-only file and passed to curl on stdin, never in argv or the log.
- Keeps the newest 5 releases and never prunes the current or previous one.
- Only touches its own root folder and containers with its own name prefix.

## Tests

```
bash test/run_tests.sh
```

Runs the real script against a mock GitHub API (`test/mock_github.py`) and a local web server. No network, no Docker. 27 checks, including:

| Scenario | Expected |
|---|---|
| Approved by the other person | deploys |
| Approved only by the author | refused |
| Approval on an older commit | refused |
| Approval later withdrawn | refused |
| Approver not on the list | refused |
| Commit not on main | refused |
| Direct push (not a PR merge commit) | refused |
| Checksum mismatch | refused |
| New release fails its health check | refused and rolled back automatically |
| Injection attempts (`release-x;id`, `bash -i`, extra arguments) | refused |
| Rollback, pruning, status | work as described |
| Token in the log | never |

A mutation check is a good habit here: remove the "not the author" condition from `bin/deploy` and the suite fails on self-approval straight away.

CI runs shellcheck and the test suite on every push (`.github/workflows/test.yml`).

## Using it

1. Edit the settings block at the top of `bin/deploy`: org, repo names, health URLs, container names.
2. Install it as `/opt/app/bin/deploy`, owned by root, mode 0755.
3. Create a `deploy` user, put the forced-command key line above in its `authorized_keys`, and allow it `sudo /opt/app/bin/deploy` with `env_keep += "SSH_ORIGINAL_COMMAND"`.
4. Put a fine-grained, read-only GitHub token in `/opt/app/.deploy-token` (root only, 0600) and the approver logins in `/opt/app/etc/approvers`.
5. Have your release workflow publish `<component>-<tag>.tar.gz` and `<component>-<tag>.tar.gz.sha256` as release assets, then run `ssh deploy@host frontend <tag>`.

## Limits

- It trusts GitHub's API and the token's account. Anyone who controls an approver's GitHub account can approve.
- Backend rollback switches code only; data written by newer migrations stays.
- Built for one host. More hosts means running it on each.

## License

MIT. See `LICENSE`.

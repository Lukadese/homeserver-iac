# Contributing

Thanks for wanting to help! This project aims to be the easiest way to run a fully automated media homeserver — contributions that make it simpler, more generic or more reliable are very welcome.

## Where to go

- 🐛 **Found a bug?** Open an [Issue](../../issues) with what you expected, what happened, and your setup (OS, disk layout, VPN provider).
- ❓ **Question or setup help?** Start a [Discussion](../../discussions) — Issues are kept for bugs and feature work.
- 💡 **Feature idea?** Open an Issue first so we can discuss it before you build it.

## Project philosophy

Changes are judged against three goals — please keep them in mind:

1. **Plug and play** — a newcomer should get from blank server to running stack with `./setup.sh` and nothing else.
2. **Generic** — everything must work for 1 disk or 10, with or without a backup drive, on any Gluetun-supported VPN. No hardcoded assumptions about someone's hardware.
3. **Low maintenance** — the server must keep itself healthy between deploys. Avoid adding components that need babysitting.

## Pull requests

- Branch from `main`, keep PRs focused on one thing.
- CI must pass. You can run the same checks locally:

  ```bash
  # Ansible roles & playbook
  ansible-lint ansible/site.yml

  # Compose file (including optional profile-gated services)
  docker compose -f compose/docker-compose.yml --profile "*" config -q

  # Setup wizard syntax
  bash -n setup.sh
  ```

- If you change behaviour, update `README.md` / `BOOTSTRAP.md` in the same PR.
- Comments, task names and docs are in English.
- Never commit secrets — real values live in an encrypted, git-ignored `vault.yml` (see `ansible/inventory/group_vars/vault.yml.example`).

## Testing

There is no test cluster: changes to roles or the wizard should be tested against a real or virtual Debian machine (a VM with a couple of small virtual disks works fine). Mention in your PR how you tested.

# Proxmox

This directory is reserved for Proxmox infrastructure code and notes.

Add Proxmox modules, automation, or host documentation here rather than under
`k3s/`.

## Subdirectories

- [`keys/`](keys/) - Shared public SSH keys that Proxmox automation can inject
  into VMs with cloud-init. Public keys only; never commit private keys.
- [`k3s-worker-vm/`](k3s-worker-vm/) - Native Proxmox `qm` automation for
  creating an Ubuntu Server cloud-init VM template and cloning k3s worker VMs.
- [`openclaw/`](openclaw/) - Proxmox LXC automation for OpenClaw.

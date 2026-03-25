---
name: colima-setup
description: Configure Colima with optimal resources (alternative to Docker Desktop/OrbStack)
user_invocable: true
---

# Colima Setup

Configure Colima with sensible resource allocation for this Mac. Colima is a lightweight, CLI-only Docker runtime - an alternative to Docker Desktop or OrbStack.

Uses Apple's Virtualization.framework (`vz`) for better performance than QEMU.

## What this does

1. Detects your Mac's CPU and RAM
2. Allocates ~50% of resources to Colima (adjustable)
3. Uses `vz` runtime with Rosetta for x86 container support
4. Sets 100GB disk (Docker images add up)

## Steps

First, check what resources are available:

```bash
echo "CPUs: $(sysctl -n hw.ncpu)"
echo "RAM: $(($(sysctl -n hw.memsize) / 1024 / 1024 / 1024))GB"
```

Check current Colima status:

```bash
colima status 2>/dev/null || echo "Not running"
```

If Colima is running, stop it first:

```bash
colima stop
```

Delete existing instance to reconfigure (data in Docker volumes persists if using named volumes):

```bash
colima delete --force
```

Start Colima with optimal settings. Calculate resources based on host:

```bash
# Get host resources
TOTAL_CPU=$(sysctl -n hw.ncpu)
TOTAL_RAM_GB=$(($(sysctl -n hw.memsize) / 1024 / 1024 / 1024))

# Allocate ~50% to Colima (minimum 4 CPU, 8GB RAM)
COLIMA_CPU=$((TOTAL_CPU / 2))
COLIMA_RAM=$((TOTAL_RAM_GB / 2))
[ $COLIMA_CPU -lt 4 ] && COLIMA_CPU=4
[ $COLIMA_RAM -lt 8 ] && COLIMA_RAM=8

echo "Allocating $COLIMA_CPU CPUs and ${COLIMA_RAM}GB RAM to Colima"

colima start \
  --cpu $COLIMA_CPU \
  --memory $COLIMA_RAM \
  --disk 100 \
  --vm-type vz \
  --vz-rosetta \
  --mount-type virtiofs
```

Verify it's running:

```bash
colima status
docker info | head -20
```

## Options

**More resources:** Edit the CPU/RAM calculation to use more than 50%

**Less disk:** Change `--disk 100` to a smaller value (in GB)

**No Rosetta:** Remove `--vz-rosetta` if you don't need x86 containers

**QEMU instead of vz:** Replace `--vm-type vz --vz-rosetta --mount-type virtiofs` with just `--vm-type qemu` (slower but more compatible)

## Troubleshooting

**"vz is not supported"**: You need macOS 13+ and Apple Silicon. Fall back to `--vm-type qemu`.

**"rosetta is not available"**: Run `softwareupdate --install-rosetta` first.

**Containers can't access mounted files**: Make sure you're using `--mount-type virtiofs` (default with vz).

**Out of disk space**: Increase `--disk` value and recreate with `colima delete && colima start ...`

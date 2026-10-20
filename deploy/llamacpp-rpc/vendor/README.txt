Optional offline / hub-first source bundle (avoids git clone during docker build).

Canonical hub copy (same file for every host):
  /mnt/HDDs/Alfa-AI/smb-scratch/cluster_members/_common/source-tarballs/llama.cpp.tar.gz
  SMB: \\hub\temp\cluster_members\_common\source-tarballs\llama.cpp.tar.gz

Create on hub (hub):
  sudo bash scripts/pack-llamacpp-vendor-tarball-on-hub.sh

Member sync (before docker build):
  deploy/cluster-members/_common/sync-llamacpp-vendor-from-hub.ps1  (Windows; also run from deploy-llamacpp-rpc.ps1)
  deploy/cluster-members/_common/sync-llamacpp-vendor-from-hub.sh /path/to/alfa-ai

Local manual place here named exactly: llama.cpp.tar.gz

If llama.cpp.tar.gz is missing, the Dockerfile falls back to git clone (needs network).

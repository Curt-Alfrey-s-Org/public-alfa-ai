#!/bin/bash
# .45b rank 3 preflight on inference. Does not start training.
# CUDA_VISIBLE_DEVICES selects the RTX 3060 (index 1). Index 0 is the RTX 5060.
# https://docs.pytorch.org/docs/2.14/notes/cuda.html
set -euo pipefail
export CUDA_VISIBLE_DEVICES=1
exec /home/operator/alfa-torch-cu130/bin/python /home/operator/alfa-ai/train/from-scratch/preflight.py \
  --data-dir /mnt/cluster/training/alfa-train/datasets/from-scratch/20261003T011725Z \
  --tokenizer-json /mnt/cluster/models/huggingface/hub/models--Qwen--Qwen2.5-Coder-7B-Instruct/snapshots/c03e6d358207e414f1eca0bb1891e29f1db0e242/tokenizer.json \
  --checkpoint-dir /mnt/cluster/training/alfa-train/checkpoints/from-scratch \
  --desktop-reserve-gb 0 \
  --distributed

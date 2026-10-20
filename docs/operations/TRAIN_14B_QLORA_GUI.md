# 14B QLoRA trainer (archived -- live trainer is 7B)

**Qwen2.5-Coder-14B-Instruct** QLoRA is **archived** on hub HDD. Do **not** Start 14B.

RTX 5070 **12 GB** cards cannot hold 13-14B QLoRA (~16-20 GB per replica). Axolotl lists
7-8B QLoRA at ~10-14 GB and 13-14B QLoRA at ~16-20 GB
([choosing method](https://docs.axolotl.ai/docs/choosing_method.html)).

**Live operator runbook:** [TRAIN_7B_QLORA_GUI.md](TRAIN_7B_QLORA_GUI.md)

**Archived on hub HDD (do not delete; do not GUI-Start):**

- HF cache: `/mnt/HDDs/Alfa-AI/models/huggingface/hub/models--Qwen--Qwen2.5-Coder-14B-Instruct`
- Archive scripts: `deploy/cluster-members/hub/archive-hf-14b-keep-hdd.sh`,
  `deploy/cluster-members/hub/promote-hf-14b-to-ssd.sh` (un-archive only)

See the **14B archived** section in [TRAIN_7B_QLORA_GUI.md](TRAIN_7B_QLORA_GUI.md).

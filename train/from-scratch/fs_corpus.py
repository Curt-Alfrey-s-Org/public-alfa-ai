"""Build from-scratch pretraining shards from the current tree of mapped repos.

Step 1 of docs/FROM_SCRATCH_TRAINER_PLAN.md. No GPU work.

Reads repo ids from docs/REPO_HOST_MAPPING.md. Checkout paths and the
extension/denylist filters come from deploy/training/multi-repo-corpus.repos.yaml.
File lists are ``git ls-tree -r --name-only HEAD`` (the current tree, not
history). Secret text patterns are scripts/scan_pass_jsonl.py.

Run:
  python train/from-scratch/corpus.py --out-dir <dir> --allow-missing
"""

from __future__ import annotations

import argparse
import hashlib
import json
import socket
import sys
from datetime import datetime, timezone
from pathlib import Path

_PKG = Path(__file__).resolve().parent
_REPO = _PKG.parents[1]
_SCRIPTS = _REPO / "scripts"
if str(_SCRIPTS) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS))
if str(_PKG) not in sys.path:
    sys.path.insert(0, str(_PKG))

from build_multi_repo_corpus import (  # noqa: E402
    extension_allowed,
    fixture_secret_denied,
    git_short_sha,
    git_tracked_relpaths,
    load_repos_config,
    name_denied,
    path_denied,
    read_text_file,
)
from scan_pass_jsonl import redact_text, scan_text  # noqa: E402

from fs_config import CONFIG_PATH, load_run_config  # noqa: E402
from fs_gpu import confirm_local, island_from_rows, parse_hardware_table, query_nvidia_smi  # noqa: E402
from fs_order import OrderedFile, order_files  # noqa: E402
from fs_pack import encode_documents, unk_rate, windows_from_stream, write_u32_shard  # noqa: E402
from fs_replay import git_changed_paths  # noqa: E402
from fs_repo_map import load_repo_map  # noqa: E402
from fs_secrets import is_secret_filename, user_settings_has_credentials  # noqa: E402

_DEFAULT_MAP = _REPO / "docs" / "REPO_HOST_MAPPING.md"
_DEFAULT_REPOS = _REPO / "deploy" / "training" / "multi-repo-corpus.repos.yaml"
_DEFAULT_INVENTORY = _REPO / "docs" / "NODE_INVENTORY.md"


def _stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def lookup_root(repo_id: str, repos_cfg: list[dict]) -> Path | None:
    for entry in repos_cfg:
        if str(entry.get("id", "")).strip().casefold() == repo_id.casefold():
            root = str(entry.get("root", "")).strip()
            if root:
                return Path(root).expanduser()
    home = Path.home() / repo_id
    if home.exists():
        return home
    return None


def _split_probe(files: list[OrderedFile], repo_id: str, fraction: float) -> tuple[list[OrderedFile], list[OrderedFile]]:
    if fraction <= 0 or len(files) < 2:
        return list(files), []
    train: list[OrderedFile] = []
    probe: list[OrderedFile] = []
    for item in files:
        digest = hashlib.sha256(f"{repo_id}\n{item.rel}".encode("utf-8")).digest()
        value = int.from_bytes(digest[:4], "big") / 0xFFFFFFFF
        if value < fraction:
            probe.append(item)
        else:
            train.append(item)
    if not train and probe:
        train.append(probe.pop(0))
    if not probe and len(train) >= 2:
        probe.append(train.pop())
    return train, probe


def _collect_repo(
    repo_id: str,
    root: Path,
    include_extensions: list[str],
    deny_dirs: list[str],
    deny_globs: list[str],
    max_file_bytes: int,
) -> tuple[list[OrderedFile], list[str]] | None:
    tracked = git_tracked_relpaths(root)
    if tracked is None:
        return None
    kept: list[OrderedFile] = []
    dropped: list[str] = []
    for rel in tracked:
        path = root / rel
        if not path.is_file():
            continue
        secret_name = is_secret_filename(path.name) or fixture_secret_denied(rel, path.name)
        if path_denied(rel, deny_dirs) or name_denied(path.name, deny_globs):
            if secret_name:
                dropped.append(rel)
            continue
        if secret_name:
            dropped.append(rel)
            continue
        if not extension_allowed(path, include_extensions):
            continue
        text = read_text_file(path, max_file_bytes)
        if text is None:
            continue
        if user_settings_has_credentials(path.name, text, scan_text):
            dropped.append(rel)
            continue
        redacted, _count = redact_text(text)
        if scan_text(redacted):
            dropped.append(rel)
            continue
        if not redacted.strip():
            continue
        kept.append(OrderedFile(rel=rel.replace("\\", "/"), text=redacted))
    return kept, dropped


def _gpu_report(inventory_path: Path, hostname: str, smi_names: list[str], smi_error: str | None) -> dict:
    rows = parse_hardware_table(inventory_path.read_text(encoding="utf-8"))
    island = island_from_rows(rows)
    local = confirm_local(rows, hostname, smi_names)
    confirmed = []
    if local.get("confirmed"):
        confirmed.append(
            {
                "host": local["host"],
                "roles": local["roles"],
                "smi_names": local["smi_names"],
                "other_rtx": [model for model in local["inventory_models"] if model not in {"5070", "3060"}],
            }
        )
    hosts = []
    for row in rows:
        island_models = [model for model in row.rtx_models if model in {"5070", "3060"}]
        other = [model for model in row.rtx_models if model not in {"5070", "3060"}]
        if not island_models and not other:
            continue
        hosts.append({"host": row.host, "island_models": island_models, "other_rtx": other})
    confirmed_hosts = {item["host"] for item in confirmed}
    return {
        "inventory_5070": island["5070"],
        "inventory_3060": island["3060"],
        "hosts": hosts,
        "hostname": hostname,
        "nvidia_smi_names": smi_names,
        "nvidia_smi_error": smi_error,
        "confirmed": confirmed,
        "unconfirmed_inventory_hosts": [
            host for host in [*island["5070"], *island["3060"]] if host not in confirmed_hosts
        ],
    }


def _write_split(
    out_dir: Path,
    repo_id: str,
    split: str,
    windows: list[list[int]],
    per_shard: int,
) -> list[dict]:
    written: list[dict] = []
    if per_shard < 1:
        raise ValueError("sequences_per_shard must be positive")
    for offset in range(0, len(windows), per_shard):
        chunk = windows[offset : offset + per_shard]
        shard_index = offset // per_shard
        rel = f"{split}/{repo_id}/shard-{shard_index:05d}.bin"
        write_u32_shard(out_dir / rel, chunk)
        written.append(
            {
                "file": rel,
                "repo": repo_id,
                "split": split,
                "sequences": len(chunk),
            }
        )
    return written


def _refuse_forbidden(out_dir: Path, forbidden: list[str]) -> str | None:
    if out_dir.name in forbidden:
        return f"refusing to write shard dir named {out_dir.name}"
    for name in forbidden:
        if (out_dir / name).exists():
            return f"refusing to use {out_dir} because it already contains {name}"
    return None


def _changed_rels(root: Path, replay_from: Path | None, repo_id: str) -> set[str]:
    if replay_from is None:
        return set()
    manifest_path = replay_from / "MANIFEST.json"
    if not manifest_path.is_file():
        raise ValueError(f"replay stamp has no MANIFEST.json: {replay_from}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    old_sha = str(((manifest.get("repos") or {}).get(repo_id) or {}).get("git_short_sha") or "")
    if not old_sha:
        return set()
    return set(git_changed_paths(root, old_sha))


def build_corpus(
    *,
    map_path: Path,
    repos_file: Path,
    out_dir: Path,
    tokenizer,
    inventory_path: Path,
    allow_missing: bool = False,
    dry_run: bool = False,
    seq_len: int | None = None,
    probe_fraction: float | None = None,
    seed: int | None = None,
    sequences_per_shard: int | None = None,
    hostname: str | None = None,
    smi_names: list[str] | None = None,
    smi_error: str | None = None,
    run_config: dict | None = None,
    replay_from: Path | None = None,
) -> int:
    config = run_config or load_run_config()
    forbidden = [str(name) for name in config.get("do_not_overwrite") or []]
    refusal = _refuse_forbidden(out_dir, forbidden)
    if refusal:
        print(f"ERROR {refusal}", file=sys.stderr)
        return 2

    repo_map = load_repo_map(map_path)
    repos_doc = load_repos_config(repos_file)
    include_extensions = [str(item) for item in repos_doc.get("include_extensions") or []]
    deny_dirs = [str(item) for item in repos_doc.get("deny_dirname_substrings") or []]
    deny_globs = [str(item) for item in repos_doc.get("deny_name_globs") or []]
    max_file_bytes = int(repos_doc.get("max_file_bytes", 262144))
    base_seed = int(seed if seed is not None else repos_doc.get("seed", 42))
    fraction = float(probe_fraction if probe_fraction is not None else repos_doc.get("val_fraction", 0.1))
    window = int(seq_len if seq_len is not None else config["seq_len"])
    per_shard = int(sequences_per_shard if sequences_per_shard is not None else config["sequences_per_shard"])
    repos_cfg = list(repos_doc.get("repos") or [])

    missing: list[dict[str, str]] = []
    prepared: list[dict] = []
    for repo_id in repo_map.repo_ids:
        root = lookup_root(repo_id, repos_cfg)
        if root is None or not root.is_dir():
            missing.append({"id": repo_id, "reason": "missing_checkout", "root": "" if root is None else str(root)})
            print(f"MISSING {repo_id}", file=sys.stderr)
            continue
        collected = _collect_repo(repo_id, root, include_extensions, deny_dirs, deny_globs, max_file_bytes)
        if collected is None:
            missing.append({"id": repo_id, "reason": "not_git", "root": str(root)})
            print(f"MISSING {repo_id} not a git checkout", file=sys.stderr)
            continue
        files, dropped = collected
        if dry_run:
            print(f"repo={repo_id} files={len(files)} dropped_secrets={len(dropped)} root={root}")
            continue
        train_files, probe_files = _split_probe(files, repo_id, fraction)
        train_seed = int.from_bytes(hashlib.sha256(f"{base_seed}:{repo_id}:train".encode()).digest()[:4], "big")
        probe_seed = int.from_bytes(hashlib.sha256(f"{base_seed}:{repo_id}:probe".encode()).digest()[:4], "big")
        train_ordered, train_method = order_files(train_files, train_seed)
        probe_ordered, probe_method = order_files(probe_files, probe_seed)
        try:
            changed_rels = _changed_rels(root, replay_from, repo_id)
        except (RuntimeError, ValueError) as exc:
            print(f"ERROR {exc}", file=sys.stderr)
            return 1
        changed_ordered = [item for item in files if item.rel in changed_rels]
        for split_name, ordered in (("train", train_ordered), ("probe", probe_ordered)):
            # Scan each file, not the joined stream. Patterns such as
            # postgresql://[^@]+@ treat a newline between files as part
            # of one URL. Each file was already redacted on its own.
            for item in ordered:
                if scan_text(item.text):
                    print(
                        f"ERROR packed text still matches the secret scanner: {repo_id} {split_name} {item.rel}",
                        file=sys.stderr,
                    )
                    return 3
        prepared.append(
            {
                "id": repo_id,
                "root": str(root),
                "git_short_sha": git_short_sha(root) or "",
                "dropped_secret_files": dropped,
                "train": train_ordered,
                "probe": probe_ordered,
                "changed": changed_ordered,
                "train_order": train_method,
                "probe_order": probe_method,
            }
        )
        print(
            f"repo={repo_id} train_files={len(train_ordered)} probe_files={len(probe_ordered)} "
            f"dropped_secrets={len(dropped)} order={train_method}"
        )

    if missing and not allow_missing:
        print(f"ERROR {len(missing)} mapped repos have no current git tree", file=sys.stderr)
        return 1
    if dry_run:
        print(f"dry-run repos={len(repo_map.repo_ids)} missing={len(missing)}")
        return 0
    if not prepared:
        print("ERROR no repo trees were packed", file=sys.stderr)
        return 1

    eos_id = int(tokenizer.eos_token_id)
    unk_max = float(config.get("unk_rate_max", 0.01))
    encoded: list[dict] = []
    for repo in prepared:
        content_ids: list[int] = []
        for split_name in ("train", "probe"):
            for item in repo[split_name]:
                content_ids.extend(tokenizer.encode(item.text))
        rate = unk_rate(content_ids, getattr(tokenizer, "unk_token_id", None))
        if rate > unk_max:
            fallback = config.get("tokenizer_fallback_id")
            print(
                f"ERROR tokenizer {tokenizer.tokenizer_id} unk rate {rate:.4f} exceeds {unk_max} "
                f"on {repo['id']}. Rerun with tokenizer {fallback}.",
                file=sys.stderr,
            )
            return 3
        splits: dict[str, dict] = {}
        for split_name in ("train", "probe"):
            texts = [item.text for item in repo[split_name]]
            stream = encode_documents(texts, tokenizer.encode, eos_id) if texts else []
            windows, remainder = windows_from_stream(stream, window)
            splits[split_name] = {"windows": windows, "remainder": remainder, "tokens": len(stream)}
        changed_texts = [item.text for item in repo["changed"]]
        if changed_texts:
            stream = encode_documents(changed_texts, tokenizer.encode, eos_id)
            windows, remainder = windows_from_stream(stream, window)
            splits["changed"] = {"windows": windows, "remainder": remainder, "tokens": len(stream)}
        encoded.append({**repo, "splits": splits, "unk_rate": rate})

    out_dir.mkdir(parents=True, exist_ok=True)
    shard_rows: list[dict] = []
    per_repo: dict[str, dict] = {}
    for repo in encoded:
        per_repo[repo["id"]] = {
            "git_short_sha": repo["git_short_sha"],
            "root": repo["root"],
            "dropped_secret_files": repo["dropped_secret_files"][:200],
            "dropped_secret_count": len(repo["dropped_secret_files"]),
            "train_order": repo["train_order"],
            "probe_order": repo["probe_order"],
            "train_files": len(repo["train"]),
            "probe_files": len(repo["probe"]),
            "changed_files": len(repo["changed"]),
            "unk_rate": repo["unk_rate"],
        }
        for split_name, payload in repo["splits"].items():
            rows = _write_split(out_dir, repo["id"], split_name, payload["windows"], per_shard)
            shard_rows.extend(rows)
            per_repo[repo["id"]][f"{split_name}_sequences"] = len(payload["windows"])
            per_repo[repo["id"]][f"{split_name}_remainder_tokens"] = payload["remainder"]
            per_repo[repo["id"]][f"{split_name}_tokens"] = payload["tokens"]

    host = hostname if hostname is not None else socket.gethostname()
    gpu = _gpu_report(inventory_path, host, [] if smi_names is None else smi_names, smi_error)
    created_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    manifest = {
        "schema_version": 1,
        "created_at": created_at,
        "step": "corpus",
        "tokenizer_id": tokenizer.tokenizer_id,
        "eos_token": getattr(tokenizer, "eos_token", config.get("tokenizer_eos_token")),
        "eos_token_id": eos_id,
        "vocab_size": getattr(tokenizer, "vocab_size", None),
        "seq_len": window,
        "dtype": "uint32le",
        "fim": False,
        "precision": "bf16",
        "packing": "eos-after-each-file",
        "map_path": str(map_path),
        "repos_file": str(repos_file),
        "repo_ids": repo_map.repo_ids,
        "skipped_map_rows": repo_map.skipped_rows,
        "missing_repos": missing,
        "repos": per_repo,
        "shards": shard_rows,
        "gpu_island": gpu,
        "hub": config.get("hub"),
    }
    (out_dir / "MANIFEST.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    run_copy = dict(config)
    run_copy["tokenizer_id"] = tokenizer.tokenizer_id
    run_copy["eos_token_id"] = eos_id
    vocab_size = getattr(tokenizer, "vocab_size", None)
    if vocab_size is not None:
        run_copy["vocab_size"] = int(vocab_size)
    run_copy["created_at"] = created_at
    run_copy["gpu_island"] = gpu
    (out_dir / "RUN_CONFIG.json").write_text(json.dumps(run_copy, indent=2) + "\n", encoding="utf-8")
    print(f"summary shards={len(shard_rows)} repos={len(encoded)} out_dir={out_dir}")
    return 0


def _default_hub_dir(config: dict, stamp: str) -> Path | None:
    for key in ("smb", "nfs"):
        root = Path(str(config["hub"][key]))
        try:
            exists = root.exists()
        except OSError:
            exists = False
        if exists:
            return root / stamp
    return None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Pack mapped repo trees into from-scratch token shards")
    parser.add_argument("--out-dir", type=Path, help="Shard directory. Default: hub from-scratch path plus a UTC stamp.")
    parser.add_argument("--map", type=Path, default=_DEFAULT_MAP)
    parser.add_argument("--repos-file", type=Path, default=_DEFAULT_REPOS)
    parser.add_argument("--inventory", type=Path, default=_DEFAULT_INVENTORY)
    parser.add_argument("--tokenizer-json", type=Path, help="Local tokenizer.json. Default: hub HF snapshot.")
    parser.add_argument("--tokenizer-id", default=None)
    parser.add_argument("--allow-missing", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--seq-len", type=int, default=None)
    parser.add_argument("--seed", type=int, default=None)
    parser.add_argument("--probe-fraction", type=float, default=None)
    parser.add_argument("--sequences-per-shard", type=int, default=None)
    parser.add_argument("--replay-from", type=Path, help="Previous stamp. Writes a changed/ split from git diff.")
    args = parser.parse_args(argv)

    config = load_run_config(CONFIG_PATH)
    stamp = _stamp()
    if args.dry_run and args.out_dir is None:
        out_dir = _PKG / "_dry_run_unused"
        write_latest = None
    elif args.out_dir is None:
        out_dir = _default_hub_dir(config, stamp)
        if out_dir is None:
            hub = config["hub"]
            print("ERROR hub shard path is not mounted.", file=sys.stderr)
            print(f"  smb {hub['smb']}", file=sys.stderr)
            print(f"  nfs {hub['nfs']}", file=sys.stderr)
            print(f"  canonical {hub['canonical']}", file=sys.stderr)
            print("Pass --out-dir, or mount the hub dataset this repo already uses.", file=sys.stderr)
            return 2
        out_dir.parent.mkdir(parents=True, exist_ok=True)
        write_latest = out_dir.parent / "LATEST.txt"
    else:
        out_dir = args.out_dir
        if out_dir.name == "datasets" and out_dir.parent.name == "alfa-train":
            out_dir = out_dir / "from-scratch" / stamp
            write_latest = out_dir.parent / "LATEST.txt"
        else:
            write_latest = None

    tokenizer = None
    if not args.dry_run:
        from fs_tokenizer import TokenizerError, load_hf_tokenizer

        tokenizer_id = args.tokenizer_id or str(config["tokenizer_id"])
        try:
            tokenizer = load_hf_tokenizer(
                tokenizer_id,
                args.tokenizer_json,
                expected_eos=str(config.get("tokenizer_eos_token") or ""),
            )
        except TokenizerError as exc:
            print(f"ERROR {exc}", file=sys.stderr)
            return 4

    smi_names, smi_error = query_nvidia_smi()
    code = build_corpus(
        map_path=args.map,
        repos_file=args.repos_file,
        out_dir=out_dir,
        tokenizer=tokenizer,
        inventory_path=args.inventory,
        allow_missing=args.allow_missing,
        dry_run=args.dry_run,
        seq_len=args.seq_len,
        probe_fraction=args.probe_fraction,
        seed=args.seed,
        sequences_per_shard=args.sequences_per_shard,
        smi_names=smi_names,
        smi_error=smi_error,
        run_config=config,
        replay_from=args.replay_from,
    )
    if code == 0 and write_latest is not None and not args.dry_run:
        write_latest.write_text(out_dir.name + "\n", encoding="utf-8")
    return code


if __name__ == "__main__":
    raise SystemExit(main())

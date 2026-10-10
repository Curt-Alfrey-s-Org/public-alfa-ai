"""Corpus tool for the from-scratch trainer (plan step 1)."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

_PKG = Path(__file__).resolve().parents[1] / "train" / "from-scratch"
sys.path.insert(0, str(_PKG))

from fs_corpus import build_corpus  # noqa: E402
from fs_gpu import confirm_local, island_from_rows, parse_hardware_table  # noqa: E402
from fs_order import OrderedFile, order_files  # noqa: E402
from fs_pack import encode_documents, read_u32_shard, windows_from_stream  # noqa: E402
from fs_repo_map import parse_repo_map  # noqa: E402
from fs_secrets import is_secret_filename, user_settings_has_credentials  # noqa: E402

_REPO = Path(__file__).resolve().parents[1]


class ByteTokenizer:
    tokenizer_id = "Qwen/Qwen2.5-Coder-7B-Instruct"
    eos_token = "change-me"
    eos_token_id = 256
    unk_token_id = None

    def encode(self, text: str) -> list[int]:
        return list(text.encode("utf-8"))


def _git_commit(repo: Path, files: dict[str, str]) -> None:
    env = {
        **os.environ,
        "GIT_AUTHOR_NAME": "corpus-test",
        "GIT_AUTHOR_EMAIL": "operator@example.com",
        "GIT_COMMITTER_NAME": "corpus-test",
        "GIT_COMMITTER_EMAIL": "operator@example.com",
    }
    subprocess.run(["git", "init"], cwd=repo, check=True, capture_output=True, env=env)
    for rel, text in files.items():
        path = repo / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8", newline="\n")
    subprocess.run(["git", "add", "-A"], cwd=repo, check=True, capture_output=True, env=env)
    subprocess.run(["git", "commit", "-m", "test"], cwd=repo, check=True, capture_output=True, env=env)


def test_repo_map_uses_mapping_file_not_a_hardcoded_list() -> None:
    text = (_REPO / "docs" / "REPO_HOST_MAPPING.md").read_text(encoding="utf-8")
    parsed = parse_repo_map(text)
    ids = {repo_id.casefold() for repo_id in parsed.repo_ids}
    for required in (
        "alfa-ai",
        "victron-ble2mqtt-integration",
        "monitoring",
        "market-pie5-bot",
        "atems",
    ):
        assert required in ids
    assert "alfa-homelab" not in ids
    skipped = " ".join(parsed.skipped_rows).casefold()
    assert "probilliards" in skipped
    assert "websites" in skipped


def test_inventory_5070_and_3060_hosts_need_nvidia_smi_to_confirm() -> None:
    text = (_REPO / "docs" / "NODE_INVENTORY.md").read_text(encoding="utf-8")
    rows = parse_hardware_table(text)
    island = island_from_rows(rows)
    assert set(island["5070"]) == {"gaming-c", "gaming-b"}
    assert set(island["3060"]) == {"orchestrator", "inference"}
    assert "gaming-a" not in set(island["5070"]) | set(island["3060"])
    assert "hub" not in set(island["5070"]) | set(island["3060"])
    by_host = {row.host: row.rtx_models for row in rows}
    assert "5060" in by_host["inference"]
    assert "3060" in by_host["inference"]
    assert by_host["gaming-a"] == ("5060",)

    local = confirm_local(rows, "WOLF1", ["NVIDIA GeForce RTX 3060"])
    assert local["confirmed"] is True
    assert local["host"] == "orchestrator"
    assert local["roles"] == ["3060"]

    # A 3060 reading must not be assigned to the 5070 host just because both exist.
    mismatch = confirm_local(rows, "gaming_worker_c", ["NVIDIA GeForce RTX 3060"])
    assert mismatch["confirmed"] is False
    assert mismatch["host"] == "gaming-c"


def test_secret_filenames_and_user_settings() -> None:
    assert is_secret_filename(".env", [])
    assert is_secret_filename(".env.local", [])
    assert is_secret_filename("server.pem", [])
    assert is_secret_filename("id_ed25519", [])
    assert not is_secret_filename("main.py", [])

    def scanner(text: str) -> list:
        if "password" in text and "change-me" in text:
            return [{"pattern": "api_key_assign"}]
        return []

    assert user_settings_has_credentials("user_settings.py", 'password = "change-me"\n', scanner)
    assert not user_settings_has_credentials("user_settings.py", "debug = True\n", scanner)
    assert not user_settings_has_credentials("main.py", 'password = "change-me"\n', scanner)


def test_import_order_and_eos_between_files() -> None:
    files = [
        OrderedFile("main.py", "import helper\n"),
        OrderedFile("helper.py", "VALUE = 1\n"),
    ]
    ordered, method = order_files(files, seed=1)
    assert method == "import"
    assert [item.rel for item in ordered] == ["helper.py", "main.py"]

    mixed = ordered + [OrderedFile("README.md", "hello\n")]
    shuffled, method = order_files(mixed, seed=1)
    assert method == "random"
    assert {item.rel for item in shuffled} == {"helper.py", "main.py", "README.md"}

    stream = encode_documents([item.text for item in ordered], ByteTokenizer().encode, 256)
    assert stream[stream.index(256) + 1 :].count(256) == 1
    windows, remainder = windows_from_stream(stream, seq_len=len(stream))
    assert remainder == 0
    assert windows == [stream]
    helper_text, main_text = ByteTokenizer().encode("VALUE = 1\n"), ByteTokenizer().encode("import helper\n")
    assert stream == helper_text + [256] + main_text + [256]


def test_pack_drops_secrets_and_keeps_repos_apart(tmp_path: Path) -> None:
    sample = tmp_path / "sample-repo"
    sample.mkdir()
    secret_marker = "change-me"
    settings_marker = "USER_SETTINGS_ONLY_MARKER"
    password = "change-me"
    _git_commit(
        sample,
        {
            "helper.py": "# " + ("H" * 40) + "\n",
            "main.py": "import helper\n# " + ("M" * 40) + "\n",
            "notes.py": f"# password = {password}\n",
            ".env": f"API_TOKEN={secret_marker}\n",
            "user_settings.py": f"{settings_marker} = 1\npassword = \"change-me\"\n",
            "node_modules/left.js": "IGNORED_NODE_MODULES\n",
            "package-lock.json": "{}\n",
        },
    )
    repos_file = tmp_path / "repos.yaml"
    repos_file.write_text(
        "\n".join(
            [
                "val_fraction: 0",
                "max_file_bytes: 262144",
                "seed: 42",
                "include_extensions:",
                "  - .py",
                "  - .md",
                "  - .json",
                "deny_dirname_substrings:",
                "  - .git",
                "  - node_modules",
                "deny_name_globs:",
                "  - package-lock.json",
                "repos:",
                "  - id: sample-repo",
                "    root: " + sample.as_posix(),
                "    required: true",
                "  - id: missing-repo",
                "    root: " + (tmp_path / "no-such-repo").as_posix(),
                "    required: true",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    repo_map = tmp_path / "map.md"
    repo_map.write_text(
        "\n".join(
            [
                "| Repo / Stack | Host |",
                "| --- | --- |",
                "| sample-repo | 93 |",
                "| missing-repo | 93 |",
                "| probilliards / related | 106 |",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    inventory = tmp_path / "inventory.md"
    inventory.write_text(
        "\n".join(
            [
                "| Node | GPU |",
                "| --- | --- |",
                "| `orchestrator` Win11 (WOLF1) | RTX 3060 |",
                "| `gaming-c` gaming_worker_c | RTX 5070 |",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    out = tmp_path / "shards"
    missing_code = build_corpus(
        map_path=repo_map,
        repos_file=repos_file,
        out_dir=out,
        tokenizer=ByteTokenizer(),
        inventory_path=inventory,
        allow_missing=False,
        seq_len=32,
        probe_fraction=0,
        sequences_per_shard=4,
        hostname="not-a-host",
        smi_names=["NVIDIA GeForce RTX 3060"],
        smi_error=None,
    )
    assert missing_code == 1
    assert not (out / "MANIFEST.json").exists()

    code = build_corpus(
        map_path=repo_map,
        repos_file=repos_file,
        out_dir=out,
        tokenizer=ByteTokenizer(),
        inventory_path=inventory,
        allow_missing=True,
        seq_len=32,
        probe_fraction=0,
        sequences_per_shard=4,
        hostname="WOLF1",
        smi_names=["NVIDIA GeForce RTX 3060"],
        smi_error=None,
    )
    assert code == 0
    manifest = json.loads((out / "MANIFEST.json").read_text(encoding="utf-8"))
    run_config = json.loads((out / "RUN_CONFIG.json").read_text(encoding="utf-8"))
    assert manifest["tokenizer_id"] == "Qwen/Qwen2.5-Coder-7B-Instruct"
    assert run_config["tokenizer_id"] == "Qwen/Qwen2.5-Coder-7B-Instruct"
    assert manifest["eos_token_id"] == 256
    assert manifest["fim"] is False
    assert manifest["precision"] == "bf16"
    assert manifest["repos"]["sample-repo"]["train_order"] == "import"
    assert manifest["gpu_island"]["confirmed"][0]["host"] == "orchestrator"
    assert manifest["gpu_island"]["inventory_5070"] == ["gaming-c"]
    assert ".env" in " ".join(manifest["repos"]["sample-repo"]["dropped_secret_files"])
    assert any(path.endswith("user_settings.py") for path in manifest["repos"]["sample-repo"]["dropped_secret_files"])

    blob = b""
    for shard in manifest["shards"]:
        assert shard["repo"] == "sample-repo"
        assert not shard["file"].endswith(".jsonl")
        windows = read_u32_shard(out / shard["file"], manifest["seq_len"])
        assert windows
        assert all(len(window) == 32 for window in windows)
        for window in windows:
            blob += bytes(token for token in window if token < 256)
    text = blob.decode("utf-8", errors="replace")
    assert secret_marker not in text
    assert settings_marker not in text
    assert password not in text
    assert "IGNORED_NODE_MODULES" not in text
    assert "H" * 20 in text
    assert not (out / "alfa-corpus-train.jsonl").exists()


def test_joined_files_do_not_look_like_one_secret(tmp_path: Path) -> None:
    """A newline between files must not become one postgresql:// user:pass URL."""
    sample = tmp_path / "sample-repo"
    sample.mkdir()
    _git_commit(
        sample,
        {
            "a.py": "dsn = 'postgresql://localhost'\n",
            "b.py": "tail = 'dbuser:dbpassvalue1@db'\n",
        },
    )
    repos_file = tmp_path / "repos.yaml"
    repos_file.write_text(
        "\n".join(
            [
                "val_fraction: 0",
                "max_file_bytes: 262144",
                "seed: 1",
                "include_extensions:",
                "  - .py",
                "deny_dirname_substrings:",
                "  - .git",
                "deny_name_globs: []",
                "repos:",
                "  - id: sample-repo",
                "    root: " + sample.as_posix(),
                "    required: true",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    repo_map = tmp_path / "map.md"
    repo_map.write_text(
        "| Repo / Stack | Host |\n| --- | --- |\n| sample-repo | 93 |\n",
        encoding="utf-8",
    )
    inventory = tmp_path / "inventory.md"
    inventory.write_text(
        "| Node | GPU |\n| --- | --- |\n| `orchestrator` Win11 (WOLF1) | RTX 3060 |\n",
        encoding="utf-8",
    )
    out = tmp_path / "shards"
    code = build_corpus(
        map_path=repo_map,
        repos_file=repos_file,
        out_dir=out,
        tokenizer=ByteTokenizer(),
        inventory_path=inventory,
        allow_missing=True,
        seq_len=128,
        probe_fraction=0,
        sequences_per_shard=4,
        hostname="not-a-host",
        smi_names=[],
        smi_error=None,
    )
    assert code == 0
    assert (out / "MANIFEST.json").is_file()

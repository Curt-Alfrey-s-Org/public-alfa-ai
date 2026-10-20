"""Repo drop-ins for fleet unattended-upgrades overlay (ASCII, vendor keys)."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APT = ROOT / "deploy/cluster-members/_common/apt/51alfa-unattended"
NR = ROOT / "deploy/cluster-members/_common/needrestart/50-alfa-list-only.conf"


def test_apt_overlay_pins_reboot_off_and_blacklists() -> None:
    raw = APT.read_bytes()
    assert all(b < 128 for b in raw)
    text = raw.decode("ascii")
    assert 'Unattended-Upgrade::Automatic-Reboot "false";' in text
    assert '"linux-";' in text
    assert '"nvidia-";' in text
    assert '"docker-";' in text


def test_needrestart_overlay_list_only() -> None:
    raw = NR.read_bytes()
    assert all(b < 128 for b in raw)
    text = raw.decode("ascii")
    assert "$nrconf{restart} = 'l';" in text

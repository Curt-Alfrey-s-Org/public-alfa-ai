from __future__ import annotations

from src.agent.skills import build_skill_prompt, list_skill_catalog, load_skill


def test_list_skill_catalog_excludes_body_instructions() -> None:
    catalog = list_skill_catalog()
    assert catalog, "expected at least one skill under skills/"
    names = {entry["name"] for entry in catalog}
    assert "audit-repo" in names
    assert "implement" in names

    audit = next(entry for entry in catalog if entry["name"] == "audit-repo")
    assert "Findings" not in audit["description"]
    assert "grep_repo" not in audit["description"]
    assert audit.get("when_to_use")

    for entry in catalog:
        assert entry["name"]
        assert entry["description"]
        body = load_skill(entry["name"])
        assert body is not None
        assert "## Skills catalog" not in body


def test_load_skill_returns_body_only() -> None:
    body = load_skill("audit-repo")
    assert body is not None
    assert "Findings" in body
    assert "## Skills catalog" not in body


def test_build_skill_prompt_includes_catalog_and_activated_body() -> None:
    for skill_name in ("implement", "audit-repo"):
        prompt = build_skill_prompt(skill_name)
        assert "## Skills catalog" in prompt
        assert f"**{skill_name}**:" in prompt
        assert f"## Skill: {skill_name}" in prompt
        body = load_skill(skill_name)
        assert body is not None
        assert body in prompt

        other_skills = [
            entry["name"]
            for entry in list_skill_catalog()
            if entry["name"] != skill_name
        ]
        for other in other_skills[:3]:
            other_body = load_skill(other)
            if other_body and len(other_body) > 120:
                assert other_body not in prompt

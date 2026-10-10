"""Order files inside one repo.

Dependency order when every packed file is Python and the import graph is a
DAG. Otherwise a seeded shuffle. Cycles and syntax errors are not a partial
order; the whole repo falls back to the shuffle.
"""

from __future__ import annotations

import ast
import random
from dataclasses import dataclass

_MAX_CHEAP_FILES = 8000


@dataclass(frozen=True)
class OrderedFile:
    rel: str
    text: str


def _shuffle(files: list[OrderedFile], seed: int) -> list[OrderedFile]:
    ordered = list(files)
    random.Random(seed).shuffle(ordered)
    return ordered


def _module_to_rel(module: str, py_rels: set[str]) -> str | None:
    parts = [part for part in module.split(".") if part]
    if not parts:
        return None
    candidates = (
        "/".join(parts) + ".py",
        "/".join(parts) + "/__init__.py",
    )
    for candidate in candidates:
        if candidate in py_rels:
            return candidate
    return None


def _relative_base(file_rel: str, level: int) -> list[str] | None:
    pkg_parts = file_rel.split("/")[:-1]
    if level < 1 or level > len(pkg_parts):
        return None
    return pkg_parts[: len(pkg_parts) - (level - 1)]


def _import_targets(file_rel: str, node: ast.AST, py_rels: set[str]) -> list[str]:
    found: list[str] = []
    if isinstance(node, ast.Import):
        for alias in node.names:
            target = _module_to_rel(alias.name, py_rels)
            if target and target != file_rel:
                found.append(target)
        return found
    if not isinstance(node, ast.ImportFrom):
        return found
    level = node.level or 0
    module = node.module or ""
    if level == 0:
        target = _module_to_rel(module, py_rels) if module else None
        if target and target != file_rel:
            found.append(target)
        return found
    base = _relative_base(file_rel, level)
    if base is None:
        return found
    if module:
        target = _module_to_rel(".".join([*base, *module.split(".")]), py_rels)
        if target and target != file_rel:
            found.append(target)
        return found
    for alias in node.names:
        target = _module_to_rel(".".join([*base, alias.name]), py_rels)
        if target and target != file_rel:
            found.append(target)
    return found


def _python_edges(files: list[OrderedFile]) -> dict[str, set[str]] | None:
    py_rels = {item.rel for item in files}
    edges: dict[str, set[str]] = {item.rel: set() for item in files}
    for item in files:
        try:
            tree = ast.parse(item.text)
        except SyntaxError:
            return None
        for node in ast.walk(tree):
            if not isinstance(node, (ast.Import, ast.ImportFrom)):
                continue
            for target in _import_targets(item.rel, node, py_rels):
                edges[item.rel].add(target)
    return edges


def _topo(files: list[OrderedFile], edges: dict[str, set[str]]) -> list[OrderedFile] | None:
    """Kahn order. An edge A -> B means A imports B, so B comes first."""
    dependents: dict[str, set[str]] = {item.rel: set() for item in files}
    indegree: dict[str, int] = {item.rel: 0 for item in files}
    for src, targets in edges.items():
        for target in targets:
            if target not in indegree or target == src:
                continue
            if src not in dependents[target]:
                dependents[target].add(src)
                indegree[src] += 1
    ready = sorted(rel for rel, degree in indegree.items() if degree == 0)
    ordered_rels: list[str] = []
    while ready:
        rel = ready.pop(0)
        ordered_rels.append(rel)
        for dependent in sorted(dependents[rel]):
            indegree[dependent] -= 1
            if indegree[dependent] == 0:
                ready.append(dependent)
                ready.sort()
    if len(ordered_rels) != len(files):
        return None
    by_rel = {item.rel: item for item in files}
    return [by_rel[rel] for rel in ordered_rels]


def order_files(files: list[OrderedFile], seed: int) -> tuple[list[OrderedFile], str]:
    """Return (ordered files, method) where method is 'import' or 'random'."""
    if len(files) > _MAX_CHEAP_FILES or any(not item.rel.endswith(".py") for item in files):
        return _shuffle(files, seed), "random"
    edges = _python_edges(files)
    if edges is None:
        return _shuffle(files, seed), "random"
    ordered = _topo(files, edges)
    if ordered is None:
        return _shuffle(files, seed), "random"
    return ordered, "import"

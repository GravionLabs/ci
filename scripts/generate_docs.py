#!/usr/bin/env python3
"""
Generate and update input/output documentation tables in README.md from action.yml files.

Replaces content between marker comments in README.md:
    <!-- action-docs:inputs source="dotnet/build/action.yml" -->
    ...generated table...
    <!-- /action-docs:inputs -->

    <!-- action-docs:outputs source="versioning/determine-version/action.yml" -->
    ...generated table...
    <!-- /action-docs:outputs -->

Usage:
    python scripts/generate_docs.py [--check]

Options:
    --check     Exit with code 1 if README.md would change (for CI enforcement).
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("PyYAML is required. Install with: pip install pyyaml", file=sys.stderr)
    sys.exit(1)

REPO_ROOT = Path(__file__).parent.parent
README = REPO_ROOT / "README.md"

# Marker patterns
INPUT_START = re.compile(
    r'<!-- action-docs:inputs source="(?P<source>[^"]+)" -->'
)
INPUT_END = "<!-- /action-docs:inputs -->"
OUTPUT_START = re.compile(
    r'<!-- action-docs:outputs source="(?P<source>[^"]+)" -->'
)
OUTPUT_END = "<!-- /action-docs:outputs -->"


def load_action(source: str) -> dict:
    """Load and parse an action.yml file relative to the repo root."""
    path = REPO_ROOT / source
    if not path.exists():
        raise FileNotFoundError(f"Action file not found: {path}")
    with path.open(encoding="utf-8") as f:
        return yaml.safe_load(f)


def render_inputs_table(inputs: dict) -> str:
    """Render a markdown table for action inputs."""
    if not inputs:
        return "_No inputs._\n"

    rows = []
    for name, meta in inputs.items():
        desc = (meta.get("description") or "").replace("\n", " ").strip()
        required = "**Yes**" if meta.get("required") is True else "No"
        default = meta.get("default", "")
        if default == "" or default is None:
            default = "—" if meta.get("required") else ""
        rows.append((f"`{name}`", desc, required, str(default)))

    # Compute column widths
    headers = ("Name", "Description", "Required", "Default")
    widths = [max(len(h), max(len(r[i]) for r in rows)) for i, h in enumerate(headers)]

    def row_str(cols):
        return "| " + " | ".join(c.ljust(widths[i]) for i, c in enumerate(cols)) + " |"

    sep = "|-" + "-|-".join("-" * w for w in widths) + "-|"
    lines = [row_str(headers), sep] + [row_str(r) for r in rows]
    return "\n".join(lines) + "\n"


def render_outputs_table(outputs: dict) -> str:
    """Render a markdown table for action outputs."""
    if not outputs:
        return "_No outputs._\n"

    rows = []
    for name, meta in outputs.items():
        desc = (meta.get("description") or "").replace("\n", " ").strip()
        rows.append((f"`{name}`", desc))

    headers = ("Name", "Description")
    widths = [max(len(h), max(len(r[i]) for r in rows)) for i, h in enumerate(headers)]

    def row_str(cols):
        return "| " + " | ".join(c.ljust(widths[i]) for i, c in enumerate(cols)) + " |"

    sep = "|-" + "-|-".join("-" * w for w in widths) + "-|"
    lines = [row_str(headers), sep] + [row_str(r) for r in rows]
    return "\n".join(lines) + "\n"


def process_readme(content: str) -> tuple[str, list[str]]:
    """
    Replace all marker-bounded sections with generated tables.
    Returns (updated_content, list_of_errors).
    On any error the original section is left untouched and the error is recorded;
    the caller is responsible for deciding whether to write the file.
    """
    errors: list[str] = []
    result = []
    lines = content.splitlines(keepends=True)
    i = 0

    def _find_end_marker(start: int, end_marker: str) -> int | None:
        """Return the line index of end_marker, or None if EOF is reached first."""
        j = start
        while j < len(lines) and end_marker not in lines[j]:
            j += 1
        return j if j < len(lines) else None

    while i < len(lines):
        line = lines[i]

        # Check for inputs marker
        m = INPUT_START.search(line)
        if m:
            source = m.group("source")
            i += 1
            end_idx = _find_end_marker(i, INPUT_END)
            if end_idx is None:
                errors.append(
                    f"ERROR: Missing end marker '{INPUT_END}' for source='{source}' "
                    f"— leaving section untouched to avoid truncating README.md."
                )
                result.append(line)
                result.extend(lines[i:])
                i = len(lines)
                continue
            original_section = lines[i:end_idx]
            end_line = lines[end_idx]
            i = end_idx + 1
            try:
                action = load_action(source)
                table = render_inputs_table(action.get("inputs") or {})
                result.append(line)
                result.append(table)
                result.append(end_line)
            except Exception as e:
                errors.append(f"ERROR: Could not generate inputs for '{source}': {e} — leaving section untouched.")
                result.append(line)
                result.extend(original_section)
                result.append(end_line)
            continue

        # Check for outputs marker
        m = OUTPUT_START.search(line)
        if m:
            source = m.group("source")
            i += 1
            end_idx = _find_end_marker(i, OUTPUT_END)
            if end_idx is None:
                errors.append(
                    f"ERROR: Missing end marker '{OUTPUT_END}' for source='{source}' "
                    f"— leaving section untouched to avoid truncating README.md."
                )
                result.append(line)
                result.extend(lines[i:])
                i = len(lines)
                continue
            original_section = lines[i:end_idx]
            end_line = lines[end_idx]
            i = end_idx + 1
            try:
                action = load_action(source)
                table = render_outputs_table(action.get("outputs") or {})
                result.append(line)
                result.append(table)
                result.append(end_line)
            except Exception as e:
                errors.append(f"ERROR: Could not generate outputs for '{source}': {e} — leaving section untouched.")
                result.append(line)
                result.extend(original_section)
                result.append(end_line)
            continue

        result.append(line)
        i += 1

    return "".join(result), errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="Exit with code 1 if README.md would change (CI enforcement mode).",
    )
    args = parser.parse_args()

    original = README.read_text(encoding="utf-8")
    updated, errors = process_readme(original)

    for e in errors:
        print(e, file=sys.stderr)

    if errors:
        print(
            f"README.md not written — {len(errors)} error(s) occurred during generation.",
            file=sys.stderr,
        )
        return 1

    if args.check:
        if updated != original:
            print(
                "README.md is out of date. Run `python scripts/generate_docs.py` to update.",
                file=sys.stderr,
            )
            return 1
        print("README.md is up to date.")
        return 0

    README.write_text(updated, encoding="utf-8")
    changed = updated != original
    if changed:
        print("README.md updated.")
    else:
        print("README.md already up to date — no changes.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

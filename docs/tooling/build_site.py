#!/usr/bin/env python3
"""Build the user guide site and its PDF into build/docs-site/.

Needs the packages in requirements.txt plus `mmdc` and `typst` on PATH. The site and
the PDF share one generated copy of the guide, with each Mermaid fence replaced by an
SVG, because neither tool can render Mermaid well enough on its own.
"""

import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
TOOLING = REPO / "docs" / "tooling"
OUT = REPO / "build" / "docs-site"
GUIDE = OUT / "user-guide"
SITE = OUT / "site"
PDF = SITE / "pdf" / "document.pdf"

FENCE = re.compile(r"^```mermaid\n(.*?)^```\n", re.MULTILINE | re.DOTALL)


def run(*command):
    """Run a command, stopping the build if it fails. Its stderr reaches the terminal."""
    result = subprocess.run([str(part) for part in command])
    if result.returncode != 0:
        sys.exit(f"build_site: {command[0]} failed with exit code {result.returncode}")


def render_diagram(source, name):
    """Render one Mermaid source to img/<name>.svg and return its Markdown image."""
    mermaid_source = OUT / "mermaid" / f"{name}.mmd"
    mermaid_source.write_text(source)
    run(
        "mmdc",
        "--quiet",
        "--input", mermaid_source,
        "--output", GUIDE / "img" / f"{name}.svg",
        "--configFile", TOOLING / "mermaid-config.json",
        "--puppeteerConfigFile", REPO / "puppeteer-config.json",
    )
    print(f"rendered {name}")
    return f"![Mermaid Diagram](img/{name}.svg)\n"


def render_diagrams():
    """Replace every Mermaid fence in the copied guide and return how many there were."""
    (GUIDE / "img").mkdir()
    (OUT / "mermaid").mkdir()
    total = 0
    for page in sorted(GUIDE.glob("*.md")):
        index = -1

        def swap(match):
            nonlocal index
            index += 1
            return render_diagram(match[1], f"{page.stem}-{index}")

        text, count = FENCE.subn(swap, page.read_text())
        if count > 0:
            page.write_text(text)
            total += count
    return total


def check_no_fence_left():
    """Stop on a fence FENCE did not match, which would publish as raw Mermaid text."""
    left = [str(page.relative_to(GUIDE)) for page in GUIDE.rglob("*.md") if "```mermaid" in page.read_text()]
    if left:
        sys.exit(f"build_site: unrendered Mermaid fence in {', '.join(left)}")


def main():
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True)
    shutil.copy(REPO / "docs" / "zensical.toml", OUT)
    shutil.copytree(REPO / "docs" / "user-guide", GUIDE)

    print(f"{render_diagrams()} diagrams rendered")
    check_no_fence_left()

    run("zensical", "build", "-f", OUT / "zensical.toml")
    PDF.parent.mkdir()
    run("zensical2pdf", OUT, "--template", TOOLING / "pdf-template.typ", "-o", PDF)
    print(f"site: {SITE}")
    print(f"pdf: {PDF}")


if __name__ == "__main__":
    main()

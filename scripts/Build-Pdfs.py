# -*- coding: utf-8 -*-
"""Build the two public handbooks without local file-URI leakage."""

from __future__ import annotations

import argparse
import hashlib
import os
import posixpath
import re
import shutil
import subprocess
import tempfile
from pathlib import Path
from urllib.parse import quote, urlsplit

import markdown
from pypdf import PdfReader, PdfWriter


VERSION = "0.3.3"
REPOSITORY_BLOB = "https://github.com/wlyaaaaa/ai-cli-profile-manager/blob/main"
DOCS = {
    "docs/user/AI CLI Profile Manager 使用手册.md": "AI CLI Profile Manager 使用手册",
    "docs/user/Codex、Claude Code 与 Open Interpreter CLI 中文手册.md":
        "Codex、Claude Code 与 Open Interpreter CLI 中文手册",
}
EDGE_CANDIDATES = (
    Path(r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"),
    Path(r"C:\Program Files\Microsoft\Edge\Application\msedge.exe"),
    Path(r"C:\Program Files\Google\Chrome\Application\chrome.exe"),
    Path(r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"),
)

CSS = r"""
@page { size: A4; margin: 1.5cm 1.4cm; }
html { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
* { box-sizing: border-box; }
body { font-family: "Microsoft YaHei","微软雅黑","Segoe UI",sans-serif;
       font-size: 12px; line-height: 1.65; color: #222; }
h1 { font-size: 22px; color: #166534; border-bottom: 3px solid #22c55e; padding-bottom: 6px; }
h2 { font-size: 17px; color: #166534; border-bottom: 1px solid #bbf7d0; padding-bottom: 4px; margin-top: 22px; }
h3 { font-size: 14px; color: #15803d; margin-top: 16px; }
h4 { font-size: 13px; color: #36523b; margin-top: 12px; }
p, li { margin: 4px 0; }
table { border-collapse: collapse; width: 100%; margin: 8px 0; font-size: 10.5px; }
th, td { border: 1px solid #b7d7c2; padding: 4px 7px; text-align: left; vertical-align: top;
         overflow-wrap: anywhere; word-break: break-word; }
th { background: #ecfdf3; font-weight: 600; }
tr:nth-child(even) td { background: #fafbfc; }
tr, td, th { page-break-inside: avoid; }
code { background: #f0f2f4; padding: 1px 4px; border-radius: 3px;
       font-family: Consolas,"Courier New",monospace; font-size: 11px; color: #b5285a;
       overflow-wrap: anywhere; word-break: break-word; }
pre { background: #f6f8fa; border: 1px solid #e1e4e8; border-radius: 5px; padding: 10px 12px;
      white-space: pre-wrap; overflow-wrap: anywhere; word-break: break-word; page-break-inside: avoid; }
pre code { background: none; color: #24292e; padding: 0; white-space: inherit;
           overflow-wrap: inherit; word-break: inherit; }
blockquote { border-left: 4px solid #22c55e; background: #f0fdf4; margin: 8px 0;
             padding: 5px 14px; color: #4a5568; }
a { color: #1a8a5a; text-decoration: none; }
h1, h2, h3, h4 { page-break-after: avoid; }
"""

LINK_RE = re.compile(r"(?P<prefix>\]\()(?:<(?P<angle>[^>]+)>|(?P<plain>[^)\s]+))(?P<suffix>\))")


def public_link(target: str, source_relative: str) -> str:
    split = urlsplit(target)
    if split.scheme.lower() in {"http", "https", "mailto"}:
        return target
    if split.scheme:
        raise ValueError(f"不允许写入 PDF 的链接协议: {target}")
    source_dir = posixpath.dirname(source_relative.replace("\\", "/"))
    if split.path:
        repo_relative = posixpath.normpath(posixpath.join(source_dir, split.path))
    else:
        repo_relative = source_relative.replace("\\", "/")
    if repo_relative == ".." or repo_relative.startswith("../"):
        raise ValueError(f"相对链接逃出仓库: {target}")
    url = f"{REPOSITORY_BLOB}/{quote(repo_relative, safe='/')}"
    if split.fragment:
        url += "#" + quote(split.fragment, safe="-_.~%")
    return url


def rewrite_links(text: str, source_relative: str) -> str:
    def replace(match: re.Match[str]) -> str:
        target = match.group("angle") or match.group("plain")
        return match.group("prefix") + public_link(target, source_relative) + match.group("suffix")

    return LINK_RE.sub(replace, text)


def ps_quote(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def render_with_edge(edge: Path, html_path: Path, output_pdf: Path, profile_dir: Path) -> None:
    arguments = [
        "--headless=new",
        "--disable-gpu",
        "--no-first-run",
        "--no-pdf-header-footer",
        f"--user-data-dir={profile_dir}",
        f"--print-to-pdf={output_pdf}",
        html_path.as_uri(),
    ]
    ps_args = "@(" + ",".join(ps_quote(arg) for arg in arguments) + ")"
    command = (
        f"$p=Start-Process -FilePath {ps_quote(str(edge))} -ArgumentList {ps_args} "
        "-PassThru -Wait -WindowStyle Hidden; exit $p.ExitCode"
    )
    completed = subprocess.run(
        ["pwsh", "-NoLogo", "-NoProfile", "-Command", command], timeout=120, check=False
    )
    if completed.returncode != 0 or not output_pdf.exists() or output_pdf.stat().st_size <= 1024:
        raise RuntimeError(f"Edge PDF 生成失败，退出码 {completed.returncode}: {output_pdf}")


def finalize_pdf(input_pdf: Path, output_pdf: Path, title: str, source_sha256: str) -> None:
    reader = PdfReader(str(input_pdf))
    for page in reader.pages:
        for annotation_ref in page.get("/Annots", []):
            annotation = annotation_ref.get_object()
            action = annotation.get("/A")
            uri = str(action.get("/URI")) if action and action.get("/URI") else None
            if uri and not uri.lower().startswith(("https://", "http://", "mailto:")):
                raise ValueError(f"PDF 含不可移植 URI: {uri}")
    writer = PdfWriter()
    writer.clone_document_from_reader(reader)
    metadata = dict(reader.metadata or {})
    metadata["/Title"] = title
    metadata["/Author"] = "AI CLI Profile Manager contributors"
    metadata["/Subject"] = f"AI CLI Profile Manager {VERSION} 中文手册"
    metadata["/AICliSourceSHA256"] = source_sha256
    writer.add_metadata({str(k): str(v) for k, v in metadata.items() if v is not None})
    temp_target = output_pdf.with_name(output_pdf.name + ".new")
    with temp_target.open("wb") as stream:
        writer.write(stream)
    raw = temp_target.read_bytes().decode("latin-1", errors="ignore")
    if re.search(r"(?i)/URI\s*\(\s*file:|C:(?:/|\\)Users(?:/|\\)|AppData(?:/|\\)Local(?:/|\\)Temp|_pdfbuild_tmp", raw):
        temp_target.unlink(missing_ok=True)
        raise ValueError(f"PDF 二进制扫描发现本机路径或临时元数据: {output_pdf.name}")
    os.replace(temp_target, output_pdf)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    root = args.root.resolve()
    edge = next((path for path in EDGE_CANDIDATES if path.exists()), None)
    if edge is None:
        raise FileNotFoundError("未找到 Microsoft Edge 或 Google Chrome")

    with tempfile.TemporaryDirectory(prefix="aicli-public-pdf-") as temp_name:
        temp = Path(temp_name)
        for index, (source_relative, title) in enumerate(DOCS.items()):
            source = root / Path(source_relative)
            source_text = source.read_text(encoding="utf-8")
            normalized_source = source_text.replace("\r\n", "\n").replace("\r", "\n")
            source_sha256 = hashlib.sha256(normalized_source.encode("utf-8")).hexdigest()
            text = rewrite_links(source_text, source_relative)
            body = markdown.markdown(text, extensions=["tables", "fenced_code", "sane_lists", "toc"])
            html = (
                "<!DOCTYPE html><html lang='zh-CN'><head><meta charset='utf-8'>"
                f"<title>{title}</title><style>{CSS}</style></head><body>{body}</body></html>"
            )
            slug = f"handbook-{index}"
            html_path = temp / f"{slug}.html"
            raw_pdf = temp / f"{slug}.pdf"
            profile = temp / f"edge-{slug}"
            html_path.write_text(html, encoding="utf-8")
            render_with_edge(edge, html_path, raw_pdf, profile)
            final_pdf = root / f"{title}.pdf"
            finalize_pdf(raw_pdf, final_pdf, title, source_sha256)
            print(f"OK {final_pdf.name}: {final_pdf.stat().st_size // 1024} KiB")
            shutil.rmtree(profile, ignore_errors=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

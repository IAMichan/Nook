#!/usr/bin/env python3
"""Builds the Nook website: fills the shared partials into every page in src/ and writes the result next to this file.

Markers a page in src/ can use:
  <!-- @head title="…" desc="…" -->   the document head: meta tags, canonical URL, social cards, structured data
  <!-- @nav -->                        the top navigation
  <!-- @sprite -->                     the shared SVG icons (agent marks, folder, branch, pull request)
  <!-- @apple -->                      the Apple logo for download buttons
  <!-- @footer -->                     the footer, the shared script, and the end of the document

Besides the pages it writes what search engines and AI crawlers read:
  sitemap.xml, robots.txt, llms.txt and site.webmanifest.

The social card of a page is assets/og/<page>.png; make them with og.py after changing a page's heading.

Run it after changing anything in src/ or _partials/:  python3 site/build.py
"""
import datetime
import html
import json
import pathlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent
PARTIALS = ROOT / "_partials"

# The address the site is published at (Infaris Guard › Hosting, site "nook"). Change it here when Nook gets its own domain.
SITE = "https://nook.app.infaris.com"
REPO = "https://github.com/IAMichan/nook"

# Short page names for breadcrumbs, llms.txt and the social cards, in the order of the sitemap.
LABELS = {
    "index": "Home",
    "agents": "Agents",
    "chats": "Chats",
    "assistant": "Assistant",
    "writing": "Writing",
    "privacy": "Privacy",
    "download": "Download",
    "thanks": "Thanks",
    "browser-extension-privacy": "Browser extension privacy",
}
# Pages that are served but never indexed.
NOINDEX = {"404"}

APP_DESCRIPTION = (
    "Nook is the one calm place for everything that needs your attention: people in every chat app, "
    "coding agents such as Claude Code, Codex, Cursor and Gemini CLI, your calendar and your music. "
    "Local-first AI on your own Mac, and nothing happens without your yes."
)


def partial(name: str) -> str:
    return (PARTIALS / name).read_text().rstrip("\n")


def url_path(name: str) -> str:
    return "/" if name == "index" else f"/{name}"


def last_modified(page: pathlib.Path) -> str:
    """The date of the last commit that touched the page, or today for a page that is not committed yet."""
    try:
        out = subprocess.run(
            ["git", "log", "-1", "--format=%cs", "--", str(page)],
            cwd=ROOT, capture_output=True, text=True, check=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        out = ""
    return out or datetime.date.today().isoformat()


def text_of(fragment: str) -> str:
    fragment = re.sub(r"<br\s*/?>", " ", fragment)
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", "", fragment))).strip()


def faq(text: str) -> list[dict]:
    """The questions in a page's FAQ block (<details><summary>Q</summary><p>A</p></details>)."""
    items = []
    for block in re.findall(r'<div class="faq[^"]*">(.*?)\n\s*</div>', text, re.S):
        for q, a in re.findall(r"<details[^>]*><summary>(.*?)</summary>(.*?)</details>", block, re.S):
            items.append({
                "@type": "Question",
                "name": text_of(q),
                "acceptedAnswer": {"@type": "Answer", "text": text_of(a)},
            })
    return items


def app_node() -> dict:
    return {
        "@type": "SoftwareApplication",
        "@id": f"{SITE}/#app",
        "name": "Nook",
        "description": APP_DESCRIPTION,
        "url": f"{SITE}/",
        "image": f"{SITE}/assets/og/index.png",
        "applicationCategory": "ProductivityApplication",
        "applicationSubCategory": "DeveloperApplication",
        "operatingSystem": "macOS 15 or later (Apple Silicon); iOS companion; early Windows, Linux and Android apps",
        "downloadUrl": f"{REPO}/releases/latest",
        "installUrl": f"{SITE}/download",
        "releaseNotes": f"{REPO}/blob/main/CHANGELOG.md",
        "softwareHelp": {"@type": "CreativeWork", "url": f"{REPO}/tree/main/docs"},
        "license": f"{REPO}/blob/main/LICENSE",
        "isAccessibleForFree": True,
        "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD"},
        "inLanguage": ["en", "nl", "de", "fr", "es"],
        "featureList": [
            "One overview of everything that needs your attention",
            "Run Claude Code, Codex, Cursor, Gemini CLI and other coding agents side by side in Git worktrees",
            "One inbox for WhatsApp, Messages, Telegram, Slack, Teams, Signal, Instagram and Mail",
            "A local AI assistant with context from your screen, calendar, mail and chats",
            "AI autocomplete and dictation in every Mac app",
            "Every message, command or pull request waits for your approval",
        ],
        "author": {"@id": f"{SITE}/#org"},
        "publisher": {"@id": f"{SITE}/#org"},
        "sameAs": [REPO],
    }


def structured_data(name: str, title: str, desc: str, text: str, modified: str) -> str:
    url = SITE + url_path(name)
    org = {
        "@type": "Organization",
        "@id": f"{SITE}/#org",
        "name": "Nook",
        "url": f"{SITE}/",
        "logo": {"@type": "ImageObject", "url": f"{SITE}/assets/apple-touch-icon.png", "width": 180, "height": 180},
        "sameAs": [REPO],
    }
    website = {
        "@type": "WebSite",
        "@id": f"{SITE}/#website",
        "url": f"{SITE}/",
        "name": "Nook",
        "description": APP_DESCRIPTION,
        "inLanguage": "en",
        "publisher": {"@id": f"{SITE}/#org"},
    }
    webpage = {
        "@type": "WebPage",
        "@id": f"{url}#webpage",
        "url": url,
        "name": title,
        "description": desc,
        "inLanguage": "en",
        "isPartOf": {"@id": f"{SITE}/#website"},
        "about": {"@id": f"{SITE}/#app"},
        "primaryImageOfPage": {"@type": "ImageObject", "url": f"{SITE}/assets/og/{name}.png", "width": 1200, "height": 630},
        "dateModified": modified,
    }
    graph = [org, website, webpage]
    if name in ("index", "download"):
        graph.append(app_node())
    if name != "index":
        webpage["breadcrumb"] = {"@id": f"{url}#breadcrumb"}
        graph.append({
            "@type": "BreadcrumbList",
            "@id": f"{url}#breadcrumb",
            "itemListElement": [
                {"@type": "ListItem", "position": 1, "name": "Nook", "item": f"{SITE}/"},
                {"@type": "ListItem", "position": 2, "name": LABELS[name], "item": url},
            ],
        })
    questions = faq(text)
    if questions:
        webpage["@type"] = ["WebPage", "FAQPage"]
        webpage["mainEntity"] = questions
    data = json.dumps({"@context": "https://schema.org", "@graph": graph}, ensure_ascii=False, indent=1)
    return data.replace("</", "<\\/")


def build(page: pathlib.Path) -> str:
    name = page.stem
    text = page.read_text()
    modified = last_modified(page)

    def head(match: re.Match) -> str:
        title, desc = match["title"], match["desc"]
        indexed = name not in NOINDEX
        image_name = name if (ROOT / "assets" / "og" / f"{name}.png").exists() else "index"
        out = (
            partial("head.html")
            .replace("{{TITLE}}", title)
            .replace("{{DESC}}", desc)
            .replace("{{URL}}", SITE + url_path(name))
            .replace("{{ROBOTS}}", "index, follow, max-image-preview:large, max-snippet:-1, max-video-preview:-1" if indexed else "noindex, follow")
            .replace("{{IMAGE}}", f"{SITE}/assets/og/{image_name}.png")
            .replace("{{IMAGE_ALT}}", f"Nook · {text_of(title.split(' · ')[0])}")
        )
        if indexed:
            return out.replace("{{JSONLD}}", structured_data(name, title, desc, text, modified))
        # A page that is not indexed has no canonical address and no structured data.
        out = re.sub(r'<link rel="(canonical|alternate)"[^>]*>\n', "", out)
        out = re.sub(r'<meta property="og:url"[^>]*>\n', "", out)
        return re.sub(r'<script type="application/ld\+json">\n\{\{JSONLD\}\}\n</script>\n', "", out)

    text = re.sub(r'<!-- @head title="(?P<title>[^"]*)" desc="(?P<desc>[^"]*)" -->', head, text)
    text = text.replace("<!-- @nav -->", partial("nav.html"))
    text = text.replace("<!-- @sprite -->", partial("sprite.html"))
    text = text.replace("<!-- @apple -->", partial("apple.svg.html"))
    text = text.replace(
        "<!-- @footer -->",
        partial("footer.html") + '\n<script src="/assets/nook.js"></script>',
    )
    if "<!-- @" in text:
        raise SystemExit(f"{page.name}: unknown marker left in the page")
    return text


def page_meta(page: pathlib.Path) -> tuple[str, str]:
    m = re.search(r'<!-- @head title="([^"]*)" desc="([^"]*)" -->', page.read_text())
    if not m:
        raise SystemExit(f"{page.name}: no @head marker")
    return m[1], m[2]


def sitemap(pages: list[pathlib.Path]) -> str:
    rows = []
    for page in pages:
        priority = "1.0" if page.stem == "index" else ("0.9" if page.stem == "download" else "0.8")
        if page.stem in ("thanks", "browser-extension-privacy"):
            priority = "0.4"
        rows.append(
            f"  <url>\n    <loc>{SITE}{url_path(page.stem)}</loc>\n    <lastmod>{last_modified(page)}</lastmod>\n"
            f"    <priority>{priority}</priority>\n"
            f"    <image:image><image:loc>{SITE}/assets/og/{page.stem}.png</image:loc></image:image>\n  </url>"
        )
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" '
        'xmlns:image="http://www.google.com/schemas/sitemap-image/1.1">\n' + "\n".join(rows) + "\n</urlset>\n"
    )


def robots() -> str:
    return (
        "# Nook website. Everyone, including AI crawlers, is welcome to read the pages.\n"
        "User-agent: *\n"
        "Allow: /\n"
        "Disallow: /src/\n"
        "Disallow: /_partials/\n"
        "Disallow: /build.py\n"
        "Disallow: /og.py\n"
        "Disallow: /README.md\n"
        f"\nSitemap: {SITE}/sitemap.xml\n"
    )


def llms(pages: list[pathlib.Path]) -> str:
    lines = [
        "# Nook",
        "",
        f"> {APP_DESCRIPTION}",
        "",
        "Nook is a free, open source (MIT) app for Mac (Apple Silicon, macOS 15 or newer), with an iPhone companion and early "
        "apps for Windows, Linux and Android. Its main window is its home; the MacBook notch is an optional extra. "
        "The assistant runs on a model on your own Mac by default, and every message, command or pull request waits for your approval.",
        "",
        "## Pages",
        "",
    ]
    for page in pages:
        title, desc = page_meta(page)
        lines.append(f"- [{LABELS[page.stem]}]({SITE}{url_path(page.stem)}): {html.unescape(desc)}")
    lines += [
        "",
        "## Source",
        "",
        f"- [GitHub repository]({REPO}): the source code, issues and releases",
        f"- [Documentation]({REPO}/tree/main/docs)",
        f"- [Changelog]({REPO}/blob/main/CHANGELOG.md)",
        f"- [Latest release]({REPO}/releases/latest)",
        "",
    ]
    return "\n".join(lines)


def manifest() -> str:
    return json.dumps({
        "name": "Nook",
        "short_name": "Nook",
        "description": APP_DESCRIPTION,
        "start_url": "/",
        "display": "browser",
        "background_color": "#000000",
        "theme_color": "#000000",
        "icons": [
            {"src": "/assets/favicon.svg", "type": "image/svg+xml", "sizes": "any"},
            {"src": "/assets/apple-touch-icon.png", "type": "image/png", "sizes": "180x180"},
        ],
    }, indent=2) + "\n"


def main() -> None:
    pages = sorted((ROOT / "src").glob("*.html"))
    for page in pages:
        if page.stem not in LABELS and page.stem not in NOINDEX:
            raise SystemExit(f"{page.name}: add the page to LABELS in build.py")
        (ROOT / page.name).write_text(build(page))
        print(f"built {page.name}")
    indexed = sorted((p for p in pages if p.stem not in NOINDEX), key=lambda p: list(LABELS).index(p.stem))
    (ROOT / "sitemap.xml").write_text(sitemap(indexed))
    (ROOT / "robots.txt").write_text(robots())
    (ROOT / "llms.txt").write_text(llms(indexed))
    (ROOT / "site.webmanifest").write_text(manifest())
    print("built sitemap.xml, robots.txt, llms.txt, site.webmanifest")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Update Sumra's four README contributor sections from GitHub activity."""

import json
import os
from pathlib import Path
from urllib.request import Request, urlopen

REPOSITORY = "Ares-X/Sumra"
START = "<!-- community-contributors:start -->"
END = "<!-- community-contributors:end -->"
ELIGIBLE_ISSUE_LABELS = {"bug", "enhancement", "documentation", "community-credit"}
EXCLUDED_LABELS = {"invalid", "duplicate", "spam", "wontfix", "no-credit"}

# Heading, introduction, table columns, activity labels, empty text, next heading.
LANGUAGES = {
    "README.md": (
        "Community contributors",
        "Thanks to everyone improving Sumra through issue reports, code, and reviews. "
        "This list is automatically generated from eligible GitHub issues and merged pull requests.",
        "Contributor", "Contributions", "Issue", "PR", "Review",
        "No community contributors yet.", "License and acknowledgments",
    ),
    "README.zh-CN.md": (
        "社区贡献者",
        "感谢通过问题反馈、代码和评审帮助改进 Sumra 的每一位贡献者。"
        "此名单根据符合条件的 GitHub Issue 和已合并的 Pull Request 自动更新。",
        "贡献者", "贡献记录", "问题", "PR", "评审",
        "暂无社区贡献者。", "许可与致谢",
    ),
    "README.zh-TW.md": (
        "社群貢獻者",
        "感謝透過問題回報、程式碼與審查協助改進 Sumra 的每一位貢獻者。"
        "此名單依符合條件的 GitHub Issue 與已合併的 Pull Request 自動更新。",
        "貢獻者", "貢獻紀錄", "問題", "PR", "審查",
        "目前尚無社群貢獻者。", "授權與致謝",
    ),
    "README.ja.md": (
        "コミュニティ貢献者",
        "Issue の報告、コードの提供、レビューを通じて Sumra を改善してくださる皆さんに感謝します。"
        "この一覧は対象の GitHub Issue とマージ済み Pull Request から自動更新されます。",
        "貢献者", "貢献内容", "Issue", "PR", "レビュー",
        "コミュニティ貢献者はまだいません。", "ライセンスと謝辞",
    ),
}


def fetch_pages(path, token):
    """Fetch all pages of a GitHub REST collection."""
    entries = []
    page = 1
    while True:
        separator = "&" if "?" in path else "?"
        url = f"https://api.github.com/repos/{REPOSITORY}/{path}{separator}per_page=100&page={page}"
        request = Request(url, headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "User-Agent": "Sumra-community-contributors",
            "X-GitHub-Api-Version": "2022-11-28",
        })
        with urlopen(request, timeout=30) as response:
            batch = json.load(response)
        entries.extend(batch)
        if len(batch) < 100:
            return entries
        page += 1


def eligible_user(user):
    return user and user.get("type") != "Bot" and user["login"].lower() != "ares-x"


def has_excluded_label(item):
    return bool({label["name"].lower() for label in item.get("labels", [])} & EXCLUDED_LABELS)


def collect(issues, pulls, reviews_by_pr):
    people = {}

    def credit(user, kind, url):
        if not eligible_user(user):
            return
        login = user["login"]
        entry = people.setdefault(login.lower(), {"login": login, "issue": set(), "pr": set(), "review": set()})
        entry[kind].add(url)

    for issue in issues:
        if "pull_request" in issue or has_excluded_label(issue):
            continue
        labels = {label["name"].lower() for label in issue.get("labels", [])}
        if labels & ELIGIBLE_ISSUE_LABELS:
            credit(issue.get("user"), "issue", issue["html_url"])

    for pr in pulls:
        if not pr.get("merged_at") or has_excluded_label(pr):
            continue
        credit(pr.get("user"), "pr", pr["html_url"])
        reviewed = set()
        for review in reviews_by_pr.get(pr["number"], []):
            user = review.get("user")
            if (review.get("state") not in {"APPROVED", "CHANGES_REQUESTED"}
                    or not eligible_user(user)
                    or user["login"].lower() == pr["user"]["login"].lower()
                    or user["login"].lower() in reviewed):
                continue
            reviewed.add(user["login"].lower())
            credit(user, "review", pr["html_url"])

    return sorted(
        people.values(),
        key=lambda person: (-sum(len(person[k]) for k in ("issue", "pr", "review")), person["login"].lower()),
    )


def render(people, language):
    title, intro, name_heading, activity_heading, issue_label, pr_label, review_label, empty, _ = language
    rows = [START, f"## {title}", "", intro, ""]
    if people:
        rows += [f"| {name_heading} | {activity_heading} |", "| --- | --- |"]
        for person in people:
            login = person["login"]
            profile = f"https://github.com/{login}"
            avatar = f'<a href="{profile}"><img src="{profile}.png?size=80" alt="@{login}" width="40"></a>'
            name = f"{avatar} [@{login}]({profile})"
            links = []
            for kind, icon, label in (("issue", "📝", issue_label), ("pr", "💻", pr_label), ("review", "🔎", review_label)):
                if person[kind]:
                    references = " ".join(f"[{label} #{url.rsplit('/', 1)[-1]}]({url})" for url in sorted(person[kind], key=lambda u: int(u.rsplit('/', 1)[-1])))
                    links.append(f"{icon} {references}")
            rows.append(f"| {name} | {' · '.join(links)} |")
    else:
        rows.append(empty)
    rows.extend(["", END])
    return "\n".join(rows)


def update_readme(text, section, license_heading):
    if START in text:
        before, rest = text.split(START, 1)
        _, after = rest.split(END, 1)
        return before + section + after
    heading = f"## {license_heading}"
    if heading not in text:
        raise ValueError(f"README missing heading: {heading}")
    return text.replace(heading, section + "\n\n" + heading, 1)


def main():
    token = os.environ["GITHUB_TOKEN"]
    issues = fetch_pages("issues?state=all", token)
    pulls = fetch_pages("pulls?state=closed", token)
    reviews = {
        pr["number"]: fetch_pages(f"pulls/{pr['number']}/reviews", token)
        for pr in pulls if pr.get("merged_at") and not has_excluded_label(pr)
    }
    people = collect(issues, pulls, reviews)
    for filename, language in LANGUAGES.items():
        path = Path(filename)
        old = path.read_text(encoding="utf-8")
        new = update_readme(old, render(people, language), language[-1])
        if old != new:
            path.write_text(new, encoding="utf-8")
            print(f"Updated {filename}: {len(people)} community contributors")


if __name__ == "__main__":
    main()

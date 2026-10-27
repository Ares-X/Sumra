"""Offline tests for README community credits (no GitHub token required)."""

import importlib.util
from contextlib import redirect_stdout
from io import StringIO
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlparse

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/update-community-contributors.py"
spec = importlib.util.spec_from_file_location("contributors", SCRIPT)
contributors = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contributors)


def user(login, kind="User"):
    return {"login": login, "type": kind}


def issue(number, login, labels, **extra):
    return {
        "number": number, "html_url": f"https://github.com/Ares-X/Sumra/issues/{number}",
        "user": user(login), "labels": [{"name": label} for label in labels], **extra,
    }


def pr(number, login, merged=True):
    return {
        "number": number, "html_url": f"https://github.com/Ares-X/Sumra/pull/{number}",
        "user": user(login), "labels": [], "merged_at": "2026-10-27T00:00:00Z" if merged else None,
    }


class CommunityContributorsTests(unittest.TestCase):
    def test_all_api_collections_follow_pagination(self):
        for endpoint in ("issues?state=all", "pulls?state=closed", "pulls/10/reviews"):
            with self.subTest(endpoint=endpoint):
                first = [{"id": number} for number in range(100)]
                last = [{"id": 100}]
                responses = [StringIO(json.dumps(first)), StringIO(json.dumps(last))]
                with patch.object(contributors, "urlopen", side_effect=responses) as request:
                    self.assertEqual(contributors.fetch_pages(endpoint, "test-token"), first + last)
                urls = [urlparse(call.args[0].full_url) for call in request.call_args_list]
                self.assertEqual([parse_qs(url.query)["page"] for url in urls], [["1"], ["2"]])
                self.assertTrue(all(parse_qs(url.query)["per_page"] == ["100"] for url in urls))
                if "state=" in endpoint:
                    expected = parse_qs(urlparse(endpoint).query)["state"]
                    self.assertTrue(all(parse_qs(url.query)["state"] == expected for url in urls))

    def test_historical_issue_backfill_and_exclusions(self):
        issues = [
            issue(31, "HomeStarRunnerTron", ["bug", "enhancement"]),
            issue(42, "HomeStarRunnerTron", ["enhancement"]),
            issue(48, "2924661311", ["enhancement"]),
            issue(51, "Random", ["bug", "invalid"]),
            issue(52, "Another", []),
            issue(53, "Ares-X", ["bug"]),
            issue(54, "dependabot[bot]", ["bug"], pull_request={"url": "https://github.com/example"}),
        ]
        people = contributors.collect(issues, [], {})
        self.assertEqual([p["login"] for p in people], ["HomeStarRunnerTron", "2924661311"])
        self.assertEqual(len(people[0]["issue"]), 2)
        self.assertEqual(len(people[1]["issue"]), 1)

    def test_merged_pr_and_distinct_reviews(self):
        pulls = [pr(10, "Ares-X"), pr(11, "NewCoder"), pr(12, "Unmerged", merged=False)]
        reviews = {10: [
            {"state": "APPROVED", "user": user("Reviewer")},
            {"state": "CHANGES_REQUESTED", "user": user("Reviewer")},
            {"state": "COMMENTED", "user": user("NoCredit")},
        ], 11: [{"state": "APPROVED", "user": user("NewCoder")}]}
        people = contributors.collect([], pulls, reviews)
        self.assertEqual({p["login"] for p in people}, {"NewCoder", "Reviewer"})
        self.assertEqual(next(p for p in people if p["login"] == "Reviewer")["review"],
                         {"https://github.com/Ares-X/Sumra/pull/10"})
        self.assertEqual(next(p for p in people if p["login"] == "NewCoder")["pr"],
                         {"https://github.com/Ares-X/Sumra/pull/11"})

    def test_exclusions_apply_to_issues_pr_authors_and_reviewers(self):
        for label in contributors.EXCLUDED_LABELS:
            with self.subTest(label=label):
                excluded = pr(11, "NewCoder")
                excluded["labels"] = [{"name": label.upper()}]
                reviews = {11: [{"state": "APPROVED", "user": user("Reviewer")}]}
                self.assertEqual(contributors.collect(
                    [issue(10, "Reporter", ["BUG", label.upper()])], [excluded], reviews), [])

        reviews = {11: [
            {"state": "APPROVED", "user": user("Automation", "Bot")},
            {"state": "APPROVED", "user": user("ARES-X")},
            {"state": "DISMISSED", "user": user("Dismissed")},
            {"state": "PENDING", "user": user("Pending")},
        ]}
        self.assertEqual(contributors.collect(
            [issue(10, "Automation", ["bug"], user=user("Automation", "Bot"))],
            [pr(11, "Ares-X"), {**pr(12, "Automation"), "user": user("Automation", "Bot")}],
            reviews), [])

    def test_four_readmes_and_idempotence(self):
        people = contributors.collect([issue(42, "HomeStarRunnerTron", ["enhancement"])], [], {})
        for lang in contributors.LANGUAGES.values():
            heading = f"## {lang[-1]}"
            original = f"# Sumra\n\n{heading}\n\nLicense stuff.\n"
            section = contributors.render(people, lang)
            updated = contributors.update_readme(original, section, lang[-1])
            self.assertIn("https://github.com/HomeStarRunnerTron.png?size=80", updated)
            self.assertEqual(contributors.update_readme(updated, section, lang[-1]), updated)
            self.assertEqual(updated.count(contributors.START), 1)
            self.assertEqual(updated.count(contributors.END), 1)
            self.assertTrue(updated.endswith("License stuff.\n"))

    def test_main_preserves_actual_readmes_and_second_run_writes_nothing(self):
        root = SCRIPT.parents[1]
        originals = {name: (root / name).read_text(encoding="utf-8")
                     for name in contributors.LANGUAGES}
        issues = [issue(42, "Reporter", ["bug"])]
        pulls = [pr(10, "NewCoder")]
        reviews = [{"state": "APPROVED", "user": user("Reviewer")}]
        pages = {"issues?state=all": issues, "pulls?state=closed": pulls,
                 "pulls/10/reviews": reviews}
        previous_directory = Path.cwd()
        with tempfile.TemporaryDirectory() as directory:
            try:
                os.chdir(directory)
                for name, original in originals.items():
                    Path(name).write_text(original, encoding="utf-8")
                with patch.dict(os.environ, {"GITHUB_TOKEN": "test-token"}), \
                        patch.object(contributors, "fetch_pages", side_effect=lambda path, token: pages[path]), \
                        redirect_stdout(StringIO()):
                    contributors.main()
                    for name, original in originals.items():
                        updated = Path(name).read_text(encoding="utf-8")
                        self.assertEqual(original.split(contributors.START)[0],
                                         updated.split(contributors.START)[0])
                        self.assertEqual(original.split(contributors.END)[1],
                                         updated.split(contributors.END)[1])
                        for login in ("Reporter", "NewCoder", "Reviewer"):
                            self.assertIn(f"https://github.com/{login}.png?size=80", updated)
                        self.assertIn("docs/COMMUNITY_CONTRIBUTORS.md", updated)
                    with patch.object(Path, "write_text") as write:
                        contributors.main()
                        write.assert_not_called()
            finally:
                os.chdir(previous_directory)


if __name__ == "__main__":
    unittest.main()

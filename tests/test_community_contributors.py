"""Offline tests for README community credits (no GitHub token required)."""

import importlib.util
from pathlib import Path
import unittest

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


if __name__ == "__main__":
    unittest.main()

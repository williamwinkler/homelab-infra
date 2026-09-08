"""Fast dashboard contract tests; no Docker or external services required."""

import copy
import unittest

from validate import validate_dashboard_contract


class DashboardContractTest(unittest.TestCase):
    def setUp(self):
        self.dashboard = {
            "uid": "example",
            "templating": {"list": [{"name": "environment"}]},
            "panels": [{
                "id": 1,
                "gridPos": {"x": 0, "y": 0, "w": 12, "h": 8},
                "targets": [{"expr": 'rate(requests{env=~"${environment:regex}"}[$__rate_interval])'}],
            }],
        }
        self.dashboards = {"example": self.dashboard}

    def check_dashboard(self):
        validate_dashboard_contract(self.dashboard, "example.json", self.dashboards)

    def test_valid_variables_and_builtin_macros(self):
        self.check_dashboard()

    def test_catches_undefined_variables_inside_encoded_explore_links(self):
        self.dashboard["links"] = [{"url": "/explore?panes=%7B%22query%22%3A%22%24%7Baction%3Aregex%7D%22%7D"}]
        with self.assertRaisesRegex(SystemExit, "Undefined.*action"):
            self.check_dashboard()

    def test_nested_panel_ids_are_unique(self):
        self.dashboard["panels"][0]["panels"] = [{"id": 1}]
        with self.assertRaisesRegex(SystemExit, "Duplicate panel"):
            self.check_dashboard()

    def test_panels_must_not_overlap(self):
        second = copy.deepcopy(self.dashboard["panels"][0])
        second["id"] = 2
        self.dashboard["panels"].append(second)
        with self.assertRaisesRegex(SystemExit, "Overlapping"):
            self.check_dashboard()

    def test_local_dashboard_link_requires_existing_destination(self):
        self.dashboard["links"] = [{"url": "/d/missing?from=${__from}&to=${__to}"}]
        with self.assertRaisesRegex(SystemExit, "Unknown dashboard"):
            self.check_dashboard()

    def test_cross_link_cannot_pass_a_selector_the_destination_does_not_support(self):
        self.dashboards["other"] = {"uid": "other", "templating": {"list": []}, "panels": []}
        self.dashboard["links"] = [{"url": "/d/other?${environment:queryparam}"}]
        with self.assertRaisesRegex(SystemExit, "Unsupported.*environment"):
            self.check_dashboard()

    def test_same_dashboard_links_preserve_time_and_selector(self):
        self.dashboard["links"] = [{"url": "/d/example?from=${__from}&to=${__to}&${environment:queryparam}"}]
        self.check_dashboard()


if __name__ == "__main__":
    unittest.main()

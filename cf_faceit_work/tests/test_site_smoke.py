import html.parser
import re
import unittest
from pathlib import Path
from urllib.parse import urlsplit

REPO = Path(__file__).resolve().parents[1]
SITE = REPO / "PAGES_UPLOAD"
APP = SITE / "js" / "app.js"
CONFIG = SITE / "js" / "config.js"
SQL = REPO / "SQL" / "49_online_tournaments.sql"
ELO_SQL = REPO / "SQL" / "50_skill_based_elo_and_ai_review.sql"
AI_FUNCTION = REPO / "supabase" / "functions" / "cf-score-ai" / "index.ts"


class LocalAssets(html.parser.HTMLParser):
    def __init__(self):
        super().__init__()
        self.paths = []

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        for key in ("src", "href"):
            value = values.get(key, "")
            if value and not value.startswith(("#", "//")):
                parsed = urlsplit(value)
                if not parsed.scheme and parsed.path:
                    self.paths.append(parsed.path.lstrip("/"))


class SiteSmokeTests(unittest.TestCase):
    def test_html_local_assets_exist(self):
        parser = LocalAssets()
        parser.feed((SITE / "index.html").read_text(encoding="utf-8"))
        missing = [path for path in parser.paths if not (SITE / path).is_file()]
        self.assertEqual(missing, [], f"missing local HTML assets: {missing}")

    def test_css_local_assets_exist(self):
        css = (SITE / "css" / "site.css").read_text(encoding="utf-8")
        paths = re.findall(r"url\((?:\"|')?([^\"')]+)", css)
        missing = []
        for raw in paths:
            value = raw.strip()
            if value.startswith(("data:", "http:", "https:", "//", "#")):
                continue
            path = urlsplit(value).path.lstrip("/")
            if path and not (SITE / "css" / path).is_file() and not (SITE / path).is_file():
                missing.append(value)
        self.assertEqual(missing, [], f"missing local CSS assets: {missing}")

    def test_browser_config_does_not_contain_server_secret(self):
        config = CONFIG.read_text(encoding="utf-8").lower()
        config = re.sub(r"/\*.*?\*/", "", config, flags=re.DOTALL)
        self.assertNotRegex(config, r"service[_-]?role|sb_secret_")

    def test_legacy_demo_and_local_password_paths_are_removed(self):
        app = APP.read_text(encoding="utf-8")
        for obsolete in ("function saveAccounts", "function finishMatch", "function demoFallback", "DEFAULT_NEWS", "restoreMatch()"):
            self.assertNotIn(obsolete, app)
        for legacy_key in ("cfFaceit.accounts.v1", "cfFaceit.matches.v1", "cfFaceit.inbox.v1", "cfFaceit.news.v1"):
            self.assertIn(legacy_key, app)  # startup cleanup removes each previous demo store
        self.assertIn("cfOnlineAccount", app)

    def test_tournament_rpc_is_server_guarded(self):
        sql = SQL.read_text(encoding="utf-8")
        app = APP.read_text(encoding="utf-8")
        for routine in ("cf_tournament_state", "cf_tournament_create", "cf_tournament_join", "cf_tournament_admin_action"):
            self.assertIn(f"function public.{routine}", sql)
            self.assertIn(f"rpc('{routine}'", app)
        self.assertEqual(sql.count("set search_path = ''"), 4)
        self.assertIn("revoke all on public.cf_tournaments, public.cf_tournament_players from public, anon, authenticated", sql)
        self.assertNotIn("grant select on public.cf_tournaments", sql)
        self.assertIn("name is null or char_length(btrim(name))", sql)
        self.assertIn("v_total >= v_tournament.max_players", sql)

    def test_skill_elo_is_zero_sum_and_ai_cannot_award(self):
        sql = ELO_SQL.read_text(encoding="utf-8")
        app = APP.read_text(encoding="utf-8")
        self.assertIn("round(32.0 * (v_actual_a - v_expected_a))", sql)
        self.assertIn("if p_auto is distinct from false", sql)
        self.assertIn("grant execute on function public.cf_ai_apply_result", sql)
        self.assertIn("to service_role", sql)
        self.assertIn("cf_ai_review_claim", sql)
        self.assertIn("attempts between 0 and 3", sql)
        self.assertNotIn("perform public.cf_apply_match_result(p_match, v_winner", sql)
        self.assertNotIn("ai.applied", app)
        self.assertIn("ELO изменится только после подтверждения", app)
        self.assertNotIn("от +40 до +65", app)

    def test_ai_function_authenticates_user_bounds_image_and_checks_origin(self):
        source = AI_FUNCTION.read_text(encoding="utf-8")
        self.assertIn("auth.getUser(token)", source)
        self.assertIn("cf_ai_review_claim", source)
        self.assertIn("MAX_IMAGE_BYTES = 5_000_000", source)
        self.assertIn("parsedImageUrl.origin !== parsedProjectUrl.origin", source)
        self.assertIn("matchesImageSignature(image, mime)", source)
        self.assertIn("AbortSignal.timeout", source)
        self.assertIn("SUPABASE_SERVICE_ROLE_KEY", source)
        self.assertNotIn("service_role key value", source)

    def test_founder_setup_requires_verified_uuid(self):
        sql = (REPO / "supabase-founder-admin-setup.sql").read_text(encoding="utf-8")
        self.assertIn("v_owner_uid uuid := null", sql)
        self.assertIn("from auth.users u where u.id = v_owner_uid", sql)
        self.assertNotRegex(sql.lower(), r"where\s+lower\(nickname\)")
        self.assertNotIn("email_confirmed_at", sql)

    def test_legacy_match_setup_no_longer_grants_founder_by_nickname(self):
        for path in (REPO / "SQL" / "06_patch_match_chat_roles_p1.sql", REPO / "CF_FACEIT_PATCH_MATCH_CHAT_ROLES.sql"):
            sql = path.read_text(encoding="utf-8").lower()
            self.assertNotRegex(sql, r"update\s+public\.profiles\s+set\s+role\s*=\s*'founder'[\s\S]{0,200}where\s+lower\(nickname\)")


if __name__ == "__main__":
    unittest.main()

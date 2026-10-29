import html.parser
import json
import re
import unittest
from pathlib import Path
from urllib.parse import urlsplit
from zipfile import ZipFile

REPO = Path(__file__).resolve().parents[1]
SITE = REPO / "PAGES_UPLOAD"
APP = SITE / "js" / "app.js"
CONFIG = SITE / "js" / "config.js"
THEME = SITE / "css" / "lx-theme.css"
MAP_SQL = REPO / "SQL" / "52_lx_standoff2_maps_and_ids.sql"
FOUNDER_SQL = REPO / "SQL" / "53_lx_founder_bootstrap.sql"
BUNDLE = REPO / "LX_FACEIT_STANDOFF2"
BUNDLE_SITE = BUNDLE / "PAGES_UPLOAD"
BUNDLE_SQL = BUNDLE / "SQL" / "LX_FACEIT_FULL_SETUP.sql"
BUNDLE_ZIP = REPO / "LX_FACEIT_STANDOFF2_full.zip"


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
        missing = []
        for css_file in (SITE / "css").glob("*.css"):
            css = css_file.read_text(encoding="utf-8")
            for raw in re.findall(r"url\((?:\"|')?([^\"')]+)", css):
                value = raw.strip()
                if value.startswith(("data:", "http:", "https:", "//", "#")):
                    continue
                path = urlsplit(value).path.lstrip("/")
                if path and not (css_file.parent / path).is_file() and not (SITE / path).is_file():
                    missing.append(f"{css_file.name}: {value}")
        self.assertEqual(missing, [], f"missing local CSS assets: {missing}")

    def test_site_is_lx_standoff2_not_cf_faceit(self):
        html = (SITE / "index.html").read_text(encoding="utf-8")
        manifest = json.loads((SITE / "manifest.webmanifest").read_text(encoding="utf-8"))
        self.assertIn("LX FACEIT", html)
        self.assertIn("Standoff 2", html)
        self.assertNotIn("CF FACEIT", html)
        self.assertNotIn("CounterFlame", html)
        self.assertEqual(manifest["name"], "LX FACEIT")
        self.assertIn("Standoff 2", manifest["description"])

    def test_public_config_cannot_connect_to_other_game_or_expose_secrets(self):
        config = CONFIG.read_text(encoding="utf-8")
        config_code = re.sub(r"/\*.*?\*/", "", config, flags=re.DOTALL)
        self.assertIn("window.LX_SUPABASE_URL", config_code)
        self.assertIn("window.LX_SUPABASE_ANON_KEY", config_code)
        self.assertNotIn("window.CF_SUPABASE_URL", config_code)
        self.assertNotIn("window.CF_SUPABASE_ANON_KEY", config_code)
        self.assertNotRegex(config_code, r"window\.LX_SUPABASE_URL\s*=\s*window\.LX_SUPABASE_URL\s*\|\|\s*'https?://")
        self.assertNotRegex(config_code, r"service[_-]?role|sb_secret_")

    def test_registration_fields_and_wizard_stay_editable_offline(self):
        app = APP.read_text(encoding="utf-8")
        availability = app[app.index("function cfSetOnlineAvailability"):app.index("function boot()")]
        self.assertIn("$$('#formLogin input, #paneRegister input, #paneRegister select')", availability)
        self.assertIn("control.disabled = false", availability)
        self.assertIn("$$('#loginBtn, #forgotPassword, #registerBtn')", availability)
        self.assertIn("control.disabled = !available", availability)
        self.assertNotIn("#wizBack, #wizNext", availability)
        self.assertIn("f.focus({ preventScroll: false })", app)
        self.assertIn("if(!cfSupabaseClient){toast(", app)
        self.assertIn("cfSupabaseClient.auth.signUp", app)
        self.assertIn("Отдельная база LX FACEIT пока не подключена", app)

    def test_auth_and_dialog_windows_have_lx_responsive_refresh(self):
        theme = THEME.read_text(encoding="utf-8")
        self.assertIn(".tabs{display:grid", theme)
        self.assertIn(".auth-card{display:block;flex:none", theme)
        self.assertIn("#auth .wiz-actions{position:static", theme)
        self.assertNotIn("#auth .wiz-actions{position:sticky", theme)
        self.assertIn(".modal-root .modal{clip-path:none", theme)
        self.assertIn("@media(max-width:560px)", theme)
        self.assertIn("@media(prefers-reduced-motion:reduce)", theme)

    def test_maps_and_service_worker_use_standoff_assets(self):
        app = APP.read_text(encoding="utf-8")
        worker = (SITE / "sw.js").read_text(encoding="utf-8")
        for map_name in ("Sandstone", "Province", "Rust", "Zone 7", "Breeze", "Hanami", "Dune", "Pyramid"):
            self.assertIn(map_name, app)
            slug = map_name.lower().replace(" ", "-")
            self.assertIn(f"images/lx-map-{slug}.svg", worker)
            self.assertTrue((SITE / f"images/lx-map-{slug}.svg").is_file())
        self.assertIn("lx-faceit-standoff2", worker)

    def test_lx_migrations_are_additive_and_require_verified_founder(self):
        map_sql = MAP_SQL.read_text(encoding="utf-8")
        founder_sql = FOUNDER_SQL.read_text(encoding="utf-8")
        self.assertIn("DEDICATED LX", map_sql)
        self.assertIn("Install the LX-compatible", map_sql)
        self.assertIn("raise exception 'Queue contains legacy map values", map_sql)
        self.assertIn("raise exception 'Tournaments contain legacy map values", map_sql)
        self.assertIn("v_owner_uid uuid := null", founder_sql)
        self.assertIn("from auth.users u where u.id = v_owner_uid", founder_sql)
        self.assertNotRegex(founder_sql.lower(), r"where\s+lower\(nickname\)")
        self.assertNotRegex(founder_sql.lower(), r"password\s*=")
        self.assertNotIn("encrypted_password", founder_sql.lower())

    def test_complete_lx_bundle_has_site_database_and_login_function(self):
        self.assertTrue((BUNDLE_SITE / "index.html").is_file())
        self.assertTrue((BUNDLE_SITE / "css" / "site.css").is_file())
        self.assertTrue((BUNDLE_SITE / "css" / "lx-theme.css").is_file())
        self.assertTrue((BUNDLE_SITE / "js" / "app.js").is_file())
        self.assertTrue((BUNDLE_SITE / "js" / "config.js").is_file())
        self.assertTrue((BUNDLE / "supabase" / "functions" / "login-by-nickname" / "index.ts").is_file())
        function_source = "\n".join(path.read_text(encoding="utf-8") for path in (BUNDLE / "supabase" / "functions").rglob("*.ts"))
        self.assertNotIn("CF FACEIT", function_source)
        self.assertNotIn("CounterFlame", function_source)
        for relative in ("js/app.js", "js/config.js", "css/site.css", "css/lx-theme.css", "index.html"):
            self.assertEqual((SITE / relative).read_bytes(), (BUNDLE_SITE / relative).read_bytes(), relative)
        self.assertTrue(BUNDLE_SQL.is_file())
        with ZipFile(BUNDLE_ZIP) as archive:
            roots = {name.split("/", 1)[0] for name in archive.namelist() if not name.endswith("/")}
            self.assertEqual(roots, {"LX_FACEIT_STANDOFF2"})
            self.assertIn("LX_FACEIT_STANDOFF2/SQL/LX_FACEIT_FULL_SETUP.sql", archive.namelist())

    def test_full_setup_contains_baseline_before_lx_maps_and_avoids_data_purge(self):
        sql = BUNDLE_SQL.read_text(encoding="utf-8")
        sql_lower = sql.lower()
        self.assertLess(sql_lower.index("create table if not exists public.profiles"), sql_lower.index("included source: 52_lx_standoff2_maps_and_ids.sql"))
        for required in (
            "create table if not exists public.cf_matchmaking_queue",
            "create table if not exists public.cf_tournaments",
            "cf_auth_check_registration(text,text)",
            "cf_lobby_match_start(text,text)",
            "sandstone",
            "pyramid",
            "6,16",
            "lx faceit standoff 2 full schema installed",
        ):
            self.assertIn(required, sql_lower)
        self.assertNotIn("drop table if exists public.cf_matchmaking_queue cascade", sql_lower)
        self.assertNotIn("delete from public.cf_lobby_matches;", sql_lower)
        self.assertNotIn("Dominus", sql)


if __name__ == "__main__":
    unittest.main()

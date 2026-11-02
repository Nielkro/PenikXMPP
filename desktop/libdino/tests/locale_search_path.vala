namespace Dino.Test {

class LocaleSearchPathTest : Gee.TestCase {
    public LocaleSearchPathTest() {
        base("LocaleSearchPath");
        add_test("meson_domains_without_english_override_stale_installed_catalogs", test_meson);
        add_test("portable_domains_do_not_require_a_german_or_english_catalog", test_portable);
        add_test("explicit_catalog_directory_is_checked_per_domain", test_override);
        add_test("installed_fallback_is_used_only_without_matching_bundled_catalogs", test_fallback);
    }

    private class Fixture : Object {
        public string root;
        public string executable;
        public string installed;
        private string? previous_override;

        public Fixture() throws Error {
            root = DirUtils.make_tmp("dinox-locale-path-XXXXXX");
            executable = Path.build_filename(root, "build", "main", "dinox");
            installed = Path.build_filename(root, "installed");
            previous_override = Environment.get_variable("TEXTDOMAINDIR");
            Environment.unset_variable("TEXTDOMAINDIR");
        }

        public void catalog(string directory, string language, string domain) throws Error {
            string folder = Path.build_filename(directory, language, "LC_MESSAGES");
            DirUtils.create_with_parents(folder, 0700);
            FileUtils.set_contents(Path.build_filename(folder, domain + ".mo"), "catalog path fixture");
        }

        public void expect(string domain, string expected) {
            string actual = new SearchPathGenerator(executable).get_locale_path(domain, installed);
            fail_if_not(File.new_for_path(actual).equal(File.new_for_path(expected)), actual);
        }

        private void remove(File file) throws Error {
            if (file.query_file_type(FileQueryInfoFlags.NOFOLLOW_SYMLINKS) == FileType.DIRECTORY) {
                var children = file.enumerate_children("standard::name", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
                FileInfo? info;
                while ((info = children.next_file()) != null) remove(file.get_child(info.get_name()));
                children.close();
            }
            file.delete();
        }

        ~Fixture() {
            if (previous_override == null) Environment.unset_variable("TEXTDOMAINDIR");
            else Environment.set_variable("TEXTDOMAINDIR", previous_override, true);
            try { remove(File.new_for_path(root)); } catch (Error ignored) { }
        }
    }

    private void test_meson() {
        try {
            var fixture = new Fixture();
            foreach (string domain in new string[] { "dino", "dino-omemo", "dino-openpgp" }) {
                string bundled = domain == "dino" ? Path.build_filename(fixture.root, "build", "main", "po")
                    : Path.build_filename(fixture.root, "build", "plugins", domain.substring(5), "po");
                fixture.catalog(bundled, "ar", domain);
                fixture.catalog(fixture.installed, "en", domain);
                fixture.expect(domain, bundled);
            }
        } catch (Error error) { fail_if_reached(error.message); }
    }

    private void test_portable() {
        try {
            var fixture = new Fixture();
            fixture.executable = Path.build_filename(fixture.root, "portable", "dinox.exe");
            string bundled = Path.build_filename(fixture.root, "portable", "locale");
            foreach (string domain in new string[] { "dino", "dino-omemo", "dino-openpgp" }) {
                fixture.catalog(bundled, "fr", domain);
                fixture.expect(domain, bundled);
            }
        } catch (Error error) { fail_if_reached(error.message); }
    }

    private void test_override() {
        try {
            var fixture = new Fixture();
            string override_dir = Path.build_filename(fixture.root, "AppDir", "locale");
            fixture.catalog(override_dir, "ar", "dino");
            Environment.set_variable("TEXTDOMAINDIR", override_dir, true);
            fixture.expect("dino", override_dir);
            fixture.expect("dino-omemo", fixture.installed);
        } catch (Error error) { fail_if_reached(error.message); }
    }

    private void test_fallback() {
        try {
            var fixture = new Fixture();
            fixture.catalog(Path.build_filename(fixture.root, "build", "main", "po"), "ar", "unrelated");
            fixture.expect("dino", fixture.installed);
            fail_if_not_eq_str(new SearchPathGenerator(null).get_locale_path("dino", fixture.installed), fixture.installed);
        } catch (Error error) { fail_if_reached(error.message); }
    }
}

}

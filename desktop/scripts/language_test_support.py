"""Application language -> explicit regional system locale for native tests.

UI language and regional formatting are separate settings. Egyptian Arabic and
Pidgin use their regional Arabic/English OS formats; neither is an English UI
fallback. Missing native locales are reported, never silently replaced by C.
"""
from contextlib import contextmanager
import locale
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

REGIONS = dict(item.split(":") for item in (
    "ar:ar_EG arz:ar_EG bg:bg_BG bn:bn_BD ca:ca_ES cs:cs_CZ da:da_DK "
    "de:de_DE en:en_US es:es_ES et:et_EE fi:fi_FI fr:fr_FR he:he_IL "
    "hi:hi_IN hu:hu_HU id:id_ID it:it_IT ja:ja_JP lt:lt_LT lv:lv_LV "
    "nb:nb_NO nl:nl_NL pcm:en_NG pl:pl_PL pt:pt_PT pt_BR:pt_BR ro:ro_RO "
    "ru:ru_RU sk:sk_SK sv:sv_SE tr:tr_TR uk:uk_UA ur:ur_PK vi:vi_VN "
    "yue:yue_HK zh_CN:zh_CN zh_TW:zh_TW"
).split())


@contextmanager
def native_locale(language):
    if language not in REGIONS:
        raise ValueError(f"No reviewed system-locale mapping for {language}")
    previous = locale.setlocale(locale.LC_ALL)
    old_path = os.environ.get("LOCPATH")
    region = REGIONS[language]
    # Windows CRT uses Windows locale names, Linux uses POSIX names.
    aliases = (region.replace("_", "-"), region + ".UTF-8") if os.name == "nt" else (region + ".UTF-8",)
    with tempfile.TemporaryDirectory(prefix="dinox-test-locales-") as temporary:
        try:
            selected = None
            for candidate in aliases:
                try:
                    locale.setlocale(locale.LC_ALL, candidate)
                    selected = candidate
                    break
                except locale.Error:
                    pass
            if selected is None and os.name != "nt" and shutil.which("localedef"):
                result = subprocess.run(
                    ["localedef", "--no-archive", "-i", region, "-f", "UTF-8", str(Path(temporary) / aliases[0])],
                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                    encoding="utf-8", errors="backslashreplace")
                if result.returncode == 0:
                    os.environ["LOCPATH"] = temporary
                    try:
                        locale.setlocale(locale.LC_ALL, aliases[0])
                        selected = aliases[0]
                    except locale.Error:
                        pass
                else:
                    print(result.stdout, end="")
            if selected is None:
                yield None
            else:
                env = os.environ.copy()
                env.update(LANG=selected, LC_ALL=selected, LANGUAGE=language,
                           DINOX_TEST_APP_LANGUAGE=language)
                env.pop("DINOX_UI_TEST_LOCALE_DIR", None)
                env.pop("TEXTDOMAINDIR", None)
                print(f"UI language: {language}; verified system locale: {locale.setlocale(locale.LC_ALL)}; "
                      f"decimal separator: {locale.localeconv()['decimal_point']}", flush=True)
                yield env
        finally:
            locale.setlocale(locale.LC_ALL, previous)
            if old_path is None:
                os.environ.pop("LOCPATH", None)
            else:
                os.environ["LOCPATH"] = old_path

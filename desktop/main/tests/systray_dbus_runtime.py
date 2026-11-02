#!/usr/bin/env python3
"""Exercise production SNI/menu code on a private bus, optionally behind Flatpak's policy.

The executable substitutes account/settings/window state only. The desktop side
is a small real D-Bus watcher. No running DinoX instance or user bus is contacted.
"""
import argparse
import gettext
import json
import locale
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time
import traceback

import gi
from gi.repository import Gio, GLib


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('fixture')
    parser.add_argument('manifest')
    parser.add_argument('icons')
    parser.add_argument('--catalogs')
    parser.add_argument('--language', default='en')
    parser.add_argument('--rtl', action='store_true')
    parser.add_argument('--proxy', action='store_true')
    parser.add_argument('--watcher', default='org.kde.StatusNotifierWatcher')
    parser.add_argument('--case', choices=('full', 'direction', 'label', 'registration'), default='full')
    args = parser.parse_args()
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    loop = GLib.MainLoop()
    registered = threading.Event()
    services = []
    pending = []
    delay = [False]
    interface = Gio.DBusNodeInfo.new_for_xml("""<node><interface name='org.kde.StatusNotifierWatcher'>
      <method name='RegisterStatusNotifierItem'><arg name='service' type='s' direction='in'/></method>
      </interface></node>""")

    def register(conn, sender, path, iface, name, params, invocation):
        services.append(params.unpack()[0])
        if delay[0]:
            pending.append(invocation)
        else:
            invocation.return_value(GLib.Variant('()', ()))
        registered.set()

    registration = bus.register_object('/StatusNotifierWatcher', interface.interfaces[0], register, None, None)

    def name_call(method, name=None):
        name = name or args.watcher
        params = GLib.Variant('(su)', (name, 0)) if method == 'RequestName' else GLib.Variant('(s)', (name,))
        return bus.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', method,
                             params, None, Gio.DBusCallFlags.NONE, 3000, None)

    # Start absent: ensure a late host is detected, including Cinnamon's alias.
    children = []
    result = [1]
    with tempfile.TemporaryDirectory(prefix='dinox-tray-') as temporary:
        base = Path(temporary)
        appdir = base / 'AppDir 日本語 العربية 😀'
        icon_target = appdir / 'usr/share/icons/hicolor'
        shutil.copytree(args.icons, icon_target)
        env = os.environ.copy()
        # GNU gettext deliberately ignores LANGUAGE in C/C.UTF-8 locales.
        # Use a verified base locale while varying the interface catalog.
        base_locale = None
        for candidate in ('de_DE.UTF-8', 'en_US.UTF-8'):
            try:
                locale.setlocale(locale.LC_ALL, candidate)
                base_locale = candidate
                break
            except locale.Error:
                pass
        if base_locale is None and shutil.which('localedef'):
            locale_path = base / 'locales'
            locale_path.mkdir()
            generated = subprocess.run(['localedef', '--no-archive', '-i', 'de_DE', '-f', 'UTF-8',
                                        str(locale_path / 'de_DE.UTF-8')], capture_output=True)
            if generated.returncode == 0:
                env['LOCPATH'] = str(locale_path)
                base_locale = 'de_DE.UTF-8'
        if base_locale is None:
            print('SKIP: no non-C UTF-8 locale available for translated tray labels', flush=True)
            return 77
        env.update(APPDIR=str(appdir), LANGUAGE=args.language, LANG=base_locale, LC_ALL=base_locale,
                   GTK_A11Y='none', GIO_USE_VFS='local', GSK_RENDERER='cairo', GSETTINGS_BACKEND='memory', G_DEBUG='fatal-warnings,fatal-criticals',
                   DINOX_TRAY_TEST_RTL='1' if args.rtl else '0')
        if args.catalogs:
            env['DINOX_TRAY_TEST_LOCALEDIR'] = str(Path(args.catalogs).resolve())
        # English is compiled into the source; the application deliberately
        # ships no en.mo. Missing translated catalogs must still fail.
        translation = gettext.translation('dino', args.catalogs, languages=[args.language],
                                          fallback=not args.catalogs or args.language == 'en')
        translate = translation.gettext
        with (base / 'proxy.log').open('w') as proxy_log, (base / 'app.log').open('w') as app_log:
            if args.proxy:
                command = ['xdg-dbus-proxy', env['DBUS_SESSION_BUS_ADDRESS'], str(base / 'bus'), '--filter',
                           '--own=im.dinox.dinox', '--own=im.dinox.dinox.*']
                for permission in json.loads(Path(args.manifest).read_text())['finish-args']:
                    if permission.startswith('--talk-name='):
                        command.append('--talk=' + permission.split('=', 1)[1])
                proxy = subprocess.Popen(command, stdout=proxy_log, stderr=subprocess.STDOUT)
                children.append(proxy)
                for _ in range(300):
                    if (base / 'bus').exists():
                        break
                    assert proxy.poll() is None, 'D-Bus proxy exited'
                    time.sleep(.01)
                assert (base / 'bus').exists(), 'D-Bus proxy not ready'
                env['DBUS_SESSION_BUS_ADDRESS'] = 'unix:path=' + str(base / 'bus')
            app = subprocess.Popen([str(Path(args.fixture).resolve())], env=env, stdout=app_log, stderr=subprocess.STDOUT)
            children.append(app)

            def verify():
                try:
                    time.sleep(.2)
                    name_call('RequestName')
                    assert registered.wait(5), f'{args.watcher} registration timed out'
                    service = services[-1]

                    def call(path, iface, method, params):
                        return bus.call_sync(service, path, iface, method, params, None,
                                             Gio.DBusCallFlags.NONE, 3000, None).unpack()

                    def prop(path, iface, name):
                        return call(path, 'org.freedesktop.DBus.Properties', 'Get', GLib.Variant('(ss)', (iface, name)))[0]

                    def item_prop(item, name):
                        return call('/MenuBar', 'com.canonical.dbusmenu', 'GetProperty', GLib.Variant('(is)', (item, name)))[0]

                    if args.case in ('full', 'direction'):
                        assert prop('/MenuBar', 'com.canonical.dbusmenu', 'TextDirection') == ('rtl' if args.rtl else 'ltr'), 'wrong menu direction'
                    if args.case in ('full', 'label'):
                        status = 'R&D_name__ 日本語 العربية 😀'
                        expected = (translate('Status Message: %s') % status).replace('_', '__')
                        actual = item_prop(5, 'label')
                        assert actual == expected, f'status label: {actual!r}, expected {expected!r}'
                    if args.case == 'full':
                        assert prop('/StatusNotifierItem', 'org.kde.StatusNotifierItem', 'Status') == 'Active'
                        assert prop('/StatusNotifierItem', 'org.kde.StatusNotifierItem', 'Menu') == '/MenuBar'
                        assert prop('/StatusNotifierItem', 'org.kde.StatusNotifierItem', 'IconThemePath') == str(icon_target.parent)
                        pixmaps = prop('/StatusNotifierItem', 'org.kde.StatusNotifierItem', 'IconPixmap')
                        assert {size[0] for size in pixmaps} == {32, 48}, 'both packaged icon sizes must be exported'
                        for width, height, pixels in pixmaps:
                            assert len(pixels) == width * height * 4
                            assert any(pixels[::4]), 'transparent/empty tray icon'
                        layout = call('/MenuBar', 'com.canonical.dbusmenu', 'GetLayout', GLib.Variant('(iias)', (0, -1, [])))[1]
                        assert len(layout[2]) == 11
                        for item, props, _ in layout[2]:
                            if 'label' in props:
                                assert item_prop(item, 'label') == props['label']
                            if 'icon-data' in props:
                                assert bytes(props['icon-data']).startswith(b'\x89PNG\r\n\x1a\n')
                                assert bytes(item_prop(item, 'icon-data')) == bytes(props['icon-data'])
                        assert item_prop(2, 'label') == translate('Away').replace('_', '__')
                        # Translated labels must never become protocol action identifiers.
                        for item in (2, 3, 4, 1, 6, 7, 9):
                            call('/MenuBar', 'com.canonical.dbusmenu', 'Event', GLib.Variant('(isvu)', (item, 'clicked', GLib.Variant('i', 0), 0)))
                        assert item_prop(1, 'toggle-state') == 1
                        assert item_prop(6, 'toggle-state') == 0
                        assert item_prop(7, 'toggle-state') == 0
                        app_log.flush()
                        actions = (base / 'app.log').read_text(errors='replace')
                        for key in ('away', 'dnd', 'xa', 'online'):
                            assert f'status={key}\n' in actions, 'localized presence action leaked'
                        assert 'action=preferences-page' in actions
                    if args.case == 'full' and args.watcher == 'org.kde.StatusNotifierWatcher':
                        # One desktop may own both aliases. It must receive one
                        # registration and retain it while either name exists.
                        name_call('RequestName', 'org.x.StatusNotifierWatcher')
                        time.sleep(.15)
                        assert len(services) == 1, 'duplicate registration for one host'
                        name_call('ReleaseName')
                        time.sleep(.1)
                        assert prop('/StatusNotifierItem', 'org.kde.StatusNotifierItem', 'Status') == 'Active'
                        name_call('ReleaseName', 'org.x.StatusNotifierWatcher')
                    # Real watcher disappearance/reappearance, followed by a late
                    # registration reply after cleanup: exports must stay gone.
                    registered.clear()
                    name_call('ReleaseName')
                    time.sleep(.1)
                    delay[0] = True
                    name_call('RequestName')
                    assert registered.wait(5), 'watcher restart was not detected'
                    call('/TrayTest', 'im.dinox.TrayTest', 'Cleanup', None)
                    for invocation in pending:
                        GLib.idle_add(lambda i=invocation: (i.return_value(GLib.Variant('()', ())), False)[1])
                    time.sleep(.1)
                    for path, iface, name in (('/StatusNotifierItem', 'org.kde.StatusNotifierItem', 'Status'), ('/MenuBar', 'com.canonical.dbusmenu', 'Status')):
                        try:
                            prop(path, iface, name)
                            raise AssertionError('tray export survived cleanup')
                        except GLib.Error:
                            pass
                    assert app.poll() is None, 'late callback crashed tray fixture'
                    print(f'PASS language={args.language} rtl={args.rtl} watcher={args.watcher} proxy={args.proxy} case={args.case}', flush=True)
                    result[0] = 0
                except Exception:
                    traceback.print_exc()
                    print((base / 'app.log').read_text(errors='replace'), flush=True)
                finally:
                    GLib.idle_add(loop.quit)

            threading.Thread(target=verify, daemon=True).start()
            try:
                loop.run()
            finally:
                for child in reversed(children):
                    child.terminate()
                    try:
                        child.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        child.kill()
                        child.wait()
                bus.unregister_object(registration)
    return result[0]


if __name__ == '__main__':
    raise SystemExit(main())

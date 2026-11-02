dependencies = [
    dep_gee,
    dep_glib,
    dep_sqlcipher,
    meson.get_compiler('vala').find_library('posix'),
]
sources = files(
    'src/column.vala',
    'src/database.vala',
    'src/delete_builder.vala',
    'src/insert_builder.vala',
    'src/query_builder.vala',
    'src/row.vala',
    'src/statement_builder.vala',
    'src/table.vala',
    'src/update_builder.vala',
    'src/upsert_builder.vala',
)
c_args = [
    '-DG_LOG_DOMAIN="qlite"',
]
qlite_generated_c_args = []
if host_machine.system() == 'windows'
    # These targets contain only generated Vala C. Current MSYS2/GCC also
    # diagnoses unused cleanup helpers and finally labels emitted by Vala.
    # Match the other Vala library targets without weakening native C checks.
    qlite_generated_c_args = ['-Wno-unused-function', '-Wno-unused-label']
    c_args += qlite_generated_c_args
endif
vala_args = [
    '--vapidir', vala_source_root / 'qlite/vapi',
]
lib_qlite = library('qlite', sources, c_args: c_args, vala_args: vala_args, dependencies: dependencies, version: '0.1', install: true, install_dir: [true, true, true], install_rpath: default_install_rpath)
dep_qlite = declare_dependency(link_with: lib_qlite, include_directories: include_directories('.'))

exe_qlite_backup_test = executable('qlite-backup-test', 'tests/backup.vala',
    dependencies: dependencies + [dep_qlite], vala_args: vala_args,
    c_args: qlite_generated_c_args)
test('SQLCipher online backup', exe_qlite_backup_test, timeout: 90)

native_stream_binding_test = executable('native-stream-binding-test',
    'tests/native_stream_bindings.vala', dependencies: [dep_gio],
    vala_args: ['--pkg=dinox-native-streams'], c_args: qlite_generated_c_args)
test('Native GIO stream bindings', native_stream_binding_test)

install_data('qlite.deps', install_dir: get_option('datadir') / 'vala/vapi', install_tag: 'devel') # TODO: workaround for https://github.com/mesonbuild/meson/issues/9756

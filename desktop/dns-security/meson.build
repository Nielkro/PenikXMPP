# Remains disabled by default until package and live-account acceptance.
# Enabling this build option alone does not change any connection's policy.
dep_unbound = dependency('libunbound', version: '>=1.19', required: get_option('dnssec'))
if dep_unbound.found()
    dns_dependencies = [dep_gio, dep_unbound, dependency('openssl', version: '>=3.0')]
    if host_machine.system() == 'windows'
        dns_dependencies += [c_compiler.find_library('iphlpapi'), c_compiler.find_library('ws2_32')]
    endif
    dns_native = static_library('dinox-dns-native', 'dns-resolver.c', 'dane-verifier.c', 'openssl-context.c',
        dependencies: dns_dependencies, c_args: ['-DG_LOG_DOMAIN="dinox-dns"'])
    # libunbound is private C implementation detail, not a Vala package. Its
    # link dependency propagates through the static library automatically.
    dep_dns_native = declare_dependency(link_with: dns_native, dependencies: dep_gio,
        include_directories: include_directories('.'))
    dns_transport_dependencies = [dep_dns_native, dependency('libsoup-3.0', version: '>=3.4')]
    dns_transport = static_library('dinox-dns-transport', 'doh-forwarder.vala',
        dependencies: dns_transport_dependencies)
    dep_dns_security = declare_dependency(link_with: dns_transport,
        dependencies: dns_transport_dependencies, include_directories: include_directories('.'),
        sources: files('dns-native.vapi'))

    dns_resolver_test = executable('dns-resolver-test', 'tests/resolver-test.c',
        dependencies: dep_dns_native, install: false)
    dns_doh_test = executable('dns-doh-test', 'tests/doh-test.vala',
        dependencies: dep_dns_security, install: false)
    dns_dane_test = executable('dns-dane-test', 'tests/dane-test.c',
        dependencies: [dep_dns_native, dependency('openssl')], install: false)
    test('DANE certificate verification', dns_dane_test)
    dns_python = python.find_installation('python3', required: false)
    if dns_python.found()
        dns_fixture_modules = run_command(dns_python, '-c', 'import dns.dnssec; import cryptography', check: false)
        if dns_fixture_modules.returncode() == 0
            test('DNSSEC signed-zone resolver', dns_python,
                args: [files('tests/run-resolver-fixture.py'), dns_resolver_test], timeout: 40)
            test('DNSSEC HTTPS SOCKS5 transport', dns_python,
                args: [files('tests/run-doh-fixture.py'), dns_doh_test], timeout: 35)
            dns_h2_fixture = run_command(dns_python, '-c', 'import h2.connection', check: false)
            if dns_h2_fixture.returncode() == 0
                test('DNSSEC HTTP2 SOCKS5 transport', dns_python,
                    args: [files('tests/run-doh-http2-fixture.py'), dns_doh_test], timeout: 35)
            else
                message('DNSSEC HTTP/2 fixture not registered: Python h2 is unavailable')
            endif
        else
            message('DNSSEC fixtures not registered: Python dnspython and cryptography are unavailable')
        endif
    endif
endif

# Optional MQTT-native test: uses the same OpenSSL context as the plugin.
if dep_unbound.found()
    dns_mosquitto = dependency('libmosquitto', required: false)
    if dns_mosquitto.found()
        dns_mqtt_test = executable('dns-mqtt-tls-test', 'tests/mqtt-tls-test.c',
            dependencies: [dep_dns_native, dependency('openssl'), dns_mosquitto], install: false)
        if dns_python.found() and dns_fixture_modules.returncode() == 0
            test('MQTT DANE before CONNECT', dns_python,
                args: [files('tests/run-mqtt-tls-fixture.py'), dns_mqtt_test], timeout: 50)
        endif
    endif
endif

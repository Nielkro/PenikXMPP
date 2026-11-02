/* testcase.vala
 *
 * Copyright (C) 2009 Julien Peeters
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.

 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.

 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA
 *
 * Author:
 *     Julien Peeters <contact@julienpeeters.fr>
 */

public abstract class Gee.TestCase : Object {

    private GLib.TestSuite suite;
    private TestAdaptor[] adaptors = new TestAdaptor[0];

    [CCode (has_target = false)]
    private delegate void FixtureFunc (void* fixture, [CCode (type = "gconstpointer")] void* test_data);

    [CCode (cname = "g_test_create_case", cheader_filename = "glib.h")]
    private static extern GLib.TestCase create_test_case(string test_name, size_t data_size, [CCode (type = "gconstpointer")] void* test_data, FixtureFunc data_setup, FixtureFunc data_test, FixtureFunc data_teardown);

    protected TestCase (string name) {
        this.suite = new GLib.TestSuite (name);
    }

    public void add_test (string name, owned TestMethod test) {
        var adaptor = new TestDefaultAdaptor (name, (owned)test, this);
        this.adaptors += adaptor;

        this.suite.add (create_test_case (adaptor.name, 0, adaptor,
                                          TestDefaultAdaptor.set_up_cb,
                                          TestDefaultAdaptor.run_cb,
                                          TestDefaultAdaptor.tear_down_cb));
    }

    public void add_async_test (string name, owned AsyncTestMethod test, int timeout = 10000) {
        var adaptor = new TestAsyncAdaptor (name, (owned)test, this, timeout);
        this.adaptors += adaptor;

        this.suite.add (create_test_case (adaptor.name, 0, adaptor,
                                          TestAsyncAdaptor.set_up_cb,
                                          TestAsyncAdaptor.run_cb,
                                          TestAsyncAdaptor.tear_down_cb));
    }

    public virtual void set_up () {
    }

    public virtual void tear_down () {
    }

    public GLib.TestSuite get_suite () {
        return (owned) this.suite;
    }
}

namespace Gee {
    public delegate void TestMethod ();
    public delegate void TestFinishedCallback ();
    public delegate void AsyncTestMethod (TestFinishedCallback cb);
}

private interface Gee.TestAdaptor : Object {
}

private class Gee.TestDefaultAdaptor : Object, TestAdaptor {
    [CCode (notify = false)]
    public string name { get; private set; }
    private TestMethod test;
    private TestCase test_case;

    public TestDefaultAdaptor (string name,
    owned TestMethod test,
    TestCase test_case) {
        this.name = name;
        this.test = (owned)test;
        this.test_case = test_case;
    }

    public static void set_up_cb (void* fixture, [CCode (type = "gconstpointer")] void* test_data) {
        TestDefaultAdaptor adaptor = (TestDefaultAdaptor) test_data;
        adaptor.test_case.set_up ();
    }

    public static void run_cb (void* fixture, [CCode (type = "gconstpointer")] void* test_data) {
        TestDefaultAdaptor adaptor = (TestDefaultAdaptor) test_data;
        adaptor.test ();
    }

    public static void tear_down_cb (void* fixture, [CCode (type = "gconstpointer")] void* test_data) {
        TestDefaultAdaptor adaptor = (TestDefaultAdaptor) test_data;
        adaptor.test_case.tear_down ();
    }
}

private class Gee.TestAsyncAdaptor : Object, TestAdaptor {
    [CCode (notify = false)]
    public string name { get; private set; }
    private AsyncTestMethod test;
    private TestCase test_case;
    private MainLoop main_loop;
    private int timeout;
    private uint timeout_source = 0;

    public TestAsyncAdaptor (string name,
    owned AsyncTestMethod test,
    TestCase test_case,
    int timeout) {
        this.name = name;
        this.test = (owned)test;
        this.test_case = test_case;
        this.timeout = timeout;
    }

    public static void set_up_cb (void* fixture, [CCode (type = "gconstpointer")] void* test_data) {
        TestAsyncAdaptor adaptor = (TestAsyncAdaptor) test_data;
        adaptor.test_case.set_up ();
        adaptor.main_loop = new MainLoop ();
    }

    public static void run_cb (void* fixture, [CCode (type = "gconstpointer")] void* test_data) {
        TestAsyncAdaptor adaptor = (TestAsyncAdaptor) test_data;
        adaptor.test (adaptor.finish);
        adaptor.timeout_source = Timeout.add (adaptor.timeout, adaptor.finish_timeout);
        adaptor.main_loop.run ();
    }

    public void finish () {
        if (timeout_source != 0) {
            Source.remove(timeout_source);
            timeout_source = 0;
        }
        Idle.add (() => { main_loop.quit (); return false; });
    }

    public bool finish_timeout () {
        timeout_source = 0;
        Test.fail ();
        Test.message (@"Timeout of $(timeout)ms reached.");
        main_loop.quit ();
        return false;
    }

    public static void tear_down_cb (void* fixture, [CCode (type = "gconstpointer")] void* test_data) {
        TestAsyncAdaptor adaptor = (TestAsyncAdaptor) test_data;
        if (adaptor.timeout_source != 0) {
            Source.remove(adaptor.timeout_source);
            adaptor.timeout_source = 0;
        }
        adaptor.test_case.tear_down ();
    }
}

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
 * 	Julien Peeters <contact@julienpeeters.fr>
 */

public abstract class Gee.TestCase : Object {

    private GLib.TestSuite suite;
    private Adaptor[] adaptors = new Adaptor[0];

    public delegate void TestMethod ();

    [CCode (has_target = false)]
    private delegate void FixtureFunc (void* fixture, [CCode (type = "gconstpointer")] void* test_data);

    [CCode (cname = "g_test_create_case", cheader_filename = "glib.h")]
    private static extern GLib.TestCase create_test_case(string test_name, size_t data_size, [CCode (type = "gconstpointer")] void* test_data, FixtureFunc data_setup, FixtureFunc data_test, FixtureFunc data_teardown);

    protected TestCase (string name) {
        this.suite = new GLib.TestSuite (name);
    }

    public void add_test (string name, owned TestMethod test) {
        var adaptor = new Adaptor (name, (owned)test, this);
        this.adaptors += adaptor;

        this.suite.add (create_test_case (adaptor.name, 0, adaptor,
                                          Adaptor.set_up_cb,
                                          Adaptor.run_cb,
                                          Adaptor.tear_down_cb));
    }

    public virtual void set_up () {
    }

    public virtual void tear_down () {
    }

    public GLib.TestSuite get_suite () {
        return (owned) this.suite;
    }

    private class Adaptor {
        [CCode (notify = false)]
        public string name { get; private set; }
        private TestMethod test;
        private TestCase test_case;

        public Adaptor (string name,
        owned TestMethod test,
        TestCase test_case) {
            this.name = name;
            this.test = (owned)test;
            this.test_case = test_case;
        }

        public static void set_up_cb (void* fixture, [CCode (type = "gconstpointer")] void* test_data) {
            Adaptor adaptor = (Adaptor) test_data;
            adaptor.test_case.set_up ();
        }

        public static void run_cb (void* fixture, [CCode (type = "gconstpointer")] void* test_data) {
            Adaptor adaptor = (Adaptor) test_data;
            adaptor.test ();
        }

        public static void tear_down_cb (void* fixture, [CCode (type = "gconstpointer")] void* test_data) {
            Adaptor adaptor = (Adaptor) test_data;
            adaptor.test_case.tear_down ();
        }
    }
}

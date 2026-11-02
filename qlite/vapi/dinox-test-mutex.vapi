// Test-only view of the existing GMutex. Each capture object initializes its
// mutex exactly once and never copies or reassigns it, so direct finalization
// with g_mutex_clear is sufficient. Vala 0.56 otherwise emits unused cleanup
// helpers for RecMutex, RWLock and Cond whenever a Mutex field is finalized.
namespace DinoTest {
    [CCode (cname = "GMutex", lower_case_cprefix = "g_mutex_", cheader_filename = "glib.h", destroy_function = "g_mutex_clear", has_type_id = false, lvalue_access = false)]
    public struct Mutex {
        public Mutex();
        public void @lock();
        public void unlock();
    }
}

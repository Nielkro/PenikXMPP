namespace Dino {

public delegate void FileTransferWorkerFunc() throws Error;

public class FileTransferWorker : Object {
    private static AsyncQueue<FileTransferWorkerJob>? job_queue = null;
    private static Thread<void*>? worker_thread = null;
    private static Mutex worker_mutex;
    private static int worker_started = 0;
    private static AsyncQueue<FileTransferWorkerJob>? publish_job_queue = null;
    private static Thread<void*>? publish_worker_thread = null;
    private static Mutex publish_worker_mutex;
    private static int publish_worker_started = 0;

    public static async void run(string name, owned FileTransferWorkerFunc func) throws Error {
        ensure_started();
        SourceFunc callback = run.callback;
        MainContext callback_context = MainContext.ref_thread_default();
        var job = new FileTransferWorkerJob(name, (owned) func, (owned) callback, (owned) callback_context);
        job_queue.push(job);

        yield;

        if (job.error != null) throw (!) job.error;
    }

    public static async void run_publish(string name, owned FileTransferWorkerFunc func) throws Error {
        ensure_publish_started();
        SourceFunc callback = run_publish.callback;
        MainContext callback_context = MainContext.ref_thread_default();
        var job = new FileTransferWorkerJob(name, (owned) func, (owned) callback, (owned) callback_context);
        publish_job_queue.push(job);

        yield;

        if (job.error != null) throw (!) job.error;
    }

    private static void ensure_started() {
        worker_mutex.lock();
        try {
            if (worker_started == 0) {
                job_queue = new AsyncQueue<FileTransferWorkerJob>();
                worker_thread = new Thread<void*>("file-transfer-worker", worker_func);
                worker_started = 1;
                debug("FileTransferWorker: worker thread started");
            }
        } finally {
            worker_mutex.unlock();
        }
    }

    private static void* worker_func() {
        AsyncQueue<FileTransferWorkerJob>? queue = job_queue;
        while (queue != null) {
            FileTransferWorkerJob job = ((!) queue).pop();
            job.run();
        }
        return null;
    }

    private static void ensure_publish_started() {
        publish_worker_mutex.lock();
        try {
            if (publish_worker_started == 0) {
                publish_job_queue = new AsyncQueue<FileTransferWorkerJob>();
                publish_worker_thread = new Thread<void*>("file-transfer-publish-worker", publish_worker_func);
                publish_worker_started = 1;
                debug("FileTransferWorker: publish worker thread started");
            }
        } finally {
            publish_worker_mutex.unlock();
        }
    }

    private static void* publish_worker_func() {
        AsyncQueue<FileTransferWorkerJob>? queue = publish_job_queue;
        while (queue != null) {
            FileTransferWorkerJob job = ((!) queue).pop();
            job.run();
        }
        return null;
    }
}

private class FileTransferWorkerJob : Object {
    public string name { get; private set; }
    public Error? error { get; private set; }

    private FileTransferWorkerFunc func;
    private SourceFunc callback;
    private MainContext callback_context;

    public FileTransferWorkerJob(string name, owned FileTransferWorkerFunc func, owned SourceFunc callback, owned MainContext callback_context) {
        this.name = name;
        this.func = (owned) func;
        this.callback = (owned) callback;
        this.callback_context = (owned) callback_context;
    }

    public void run() {
        try {
            func();
        } catch (Error e) {
            error = e;
            debug("FileTransferWorker: job '%s' failed: %s", name, e.message);
        }
        var idle = new IdleSource();
        idle.set_callback((owned) callback);
        idle.attach(callback_context);
    }
}

}

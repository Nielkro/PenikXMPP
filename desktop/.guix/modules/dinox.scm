(define-module (dinox)
  #:use-module (guix)
  #:use-module (guix git-download)
  #:use-module (gnu packages audio)
  #:use-module (gnu packages check)
  #:use-module (gnu packages compression)
  #:use-module (gnu packages cpp)
  #:use-module (gnu packages databases)
  #:use-module (gnu packages gcc)
  #:use-module (gnu packages gnome)
  #:use-module (gnu packages golang-crypto)
  #:use-module (gnu packages gstreamer)
  #:use-module (gnu packages gtk)
  #:use-module (gnu packages javascript)
  #:use-module (gnu packages messaging)
  #:use-module (gnu packages networking)
  #:use-module (gnu packages pkg-config)
  #:use-module (gnu packages protobuf)
  #:use-module (gnu packages sqlite)
  #:use-module (gnu packages tcl)
  #:use-module (gnu packages tls)
  #:use-module (gnu packages tor))

;;; -for-dinox packages shouldn't be merged in Guix, as they might have configurations
;;; that could be specific to DinoX.

;;; -next packages are updates that Guix hasn't caught up yet- and they should be
;;; merged and requested.

(define %version "1.1.8.1")

(define-public dinox
  (package
    (inherit dino)
    (name "dinox")
    (version %version)
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://git.dinox.im/dinoxim/dinox")
             (commit (string-append "v" version))))
       (file-name (git-file-name name version))
       (sha256
        (base32
         "1mbh0k1nf0nw2vmlzf5zvgd2pkfnj186lxh52dkd5h71hfj0qb35"))))
    (inputs
     (modify-inputs
      (package-inputs dino)
      (replace "libnice" libnice-next)
      (replace "libomemo-c" libomemo-c-dinox)
      (append mosquitto-next)
      (append gst-plugins-bad)
      (replace "webrtc-audio-processing" webrtc-audio-processing-next)
      ;; undocumented in BUILD.md
      (replace "sqlite" sqlcipher-for-dinox)
      (append libsecret)
      (append libdbusmenu)
      (append json-glib)))
    (arguments
     (substitute-keyword-arguments (package-arguments dino)
       ((#:phases phases)
        #~(modify-phases #$phases
            (add-after 'unpack 'patch-paths
              (lambda _
                (substitute* "plugins/tor-manager/src/tor_controller.vala"
                  (("argv = \\{\"tor\"")
                   (string-append "argv = {\"" #$tor-client "/bin/tor\""))
                  (("(string\\? obfs4_path = ).*" all obfs4_path)
                   (string-append obfs4_path "\"" #$go-obfs4proxy "/bin/obfs4proxy\";")))))
            (replace 'wrap
              ;; to replace because of the executable's name...
              (lambda _
                (let* ((dinox (string-append #$output "/bin/dinox"))
                       (gst-plugin-path (getenv "GST_PLUGIN_SYSTEM_PATH")))
                  (wrap-program dinox
                    `("GST_PLUGIN_SYSTEM_PATH" ":" prefix (,gst-plugin-path))
                    `("GDK_PIXBUF_MODULE_FILE" =
                      (,(getenv "GDK_PIXBUF_MODULE_FILE")))))))))
       ((#:build-type _ #f) "release")
       ((#:configure-flags flags #~'())
        #~(cons*
           (string-append "-Dc_link_args=-Wl,-rpath="
                          #$output "/lib,-rpath="
                          #$output "/lib/dino,-rpath="
                          #$output "/lib/dino/plugins,-rpath="
                          #$output "/lib/dino/plugins/omemo")
           (string-append "-Dcpp_link_args=-Wl,-rpath="
                          #$output "/lib,-rpath="
                          #$output "/lib/dino,-rpath="
                          #$output "/lib/dino/plugins,-rpath="
                          #$output "/lib/dino/plugins/omemo")
           #$flags))))))

(define-public sqlcipher-for-dinox
  (package
    (inherit sqlcipher)
    (name "sqlcipher")
    (version "4.6.1")
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://github.com/sqlcipher/sqlcipher")
             (commit (string-append "v" version))))
       (sha256
        (base32
         "0rqwy37gz8122y23kib3z0268nndww524qp25ijbw2vb0lvzgh2m"))
       (file-name (git-file-name name version))))
    (inputs (list openssl tcl zlib))
    (arguments
     '(#:configure-flags
       '("--enable-tempstore=yes --enable-fts5"
         "CFLAGS=-DSQLITE_HAS_CODEC -DSQLITE_ENABLE_COLUMN_METADATA -DSQLITE_ENABLE_FTS3 -DSQLITE_ENABLE_FTS3_PARENTHESIS -DSQLITE_ENABLE_FTS4 -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_UNLOCK_NOTIFY -DSQLITE_ENABLE_DBSTAT_VTAB"
         "LDFLAGS=-lcrypto -ltcl8.6"
         "--disable-tcl")
       ;; tests require their own flags
       ;; see: <https://github.com/sqlcipher/sqlcipher#testing>
       #:tests? #f))))

(define-public webrtc-audio-processing-next
  (package
    (inherit webrtc-audio-processing)
    (version "2.1")
    (source
     (origin
       (method url-fetch)
       (uri
        (string-append "http://freedesktop.org/software/pulseaudio/"
                       "webrtc-audio-processing/webrtc-audio-processing-"
                       version ".tar.xz"))
       (sha256
        (base32
         "1zprz48zas5z3pqnjhj372h69i8jafqcl4q2y6ad6f109f1054xf"))))
    (propagated-inputs
     (modify-inputs (package-propagated-inputs webrtc-audio-processing)
                    (append abseil-cpp-20250127)))
    (inputs
     (modify-inputs (package-inputs webrtc-audio-processing)
                    (delete "abseil-cpp")))))

(define-public libomemo-c-dinox
  (package
    (inherit libomemo-c)
    (name "libomemo-c-dinox")
    (version "0.5.1")
    (source (origin
              (method git-fetch)
              (uri (git-reference
                    (url "https://git.dinox.im/dinoxim/libomemo-c")
                    (commit (string-append "v" version))))
              (file-name (git-file-name name version))
              (sha256
               (base32 "1xszd4cjrlwwsy19ri2ymqr676qpqqhxv3cw5zwch3lms68p51hy"))
              (modules '((guix build utils)))
              (snippet
               ;; Delete generated sources.
               #~(for-each delete-file
                           (find-files "." "\\.pb-c\\.[ch]$")))))
    (propagated-inputs
     (modify-inputs (package-propagated-inputs libomemo-c)
                    (replace "protobuf-c" protobuf-c-next)))))

(define-public mosquitto-next
  (package
    (inherit mosquitto)
    (name "mosquitto")
    (version "2.1.2")
    (source
     (origin
       (method url-fetch)
       (uri (string-append "https://mosquitto.org/files/source/mosquitto-"
                           version ".tar.gz"))
       (sha256
        (base32 "00pdrdsgvigaz7gmx383dqyrx0j194hyhy9pm6jmxihsd605747x"))))
    (arguments
     (list
      #:tests? #f
      #:configure-flags
      #~(list "-DWITH_WEBSOCKETS=ON")))
    (propagated-inputs
     (list cjson))                      ; header file included in libcommon_cjson.h
    (inputs
     (modify-inputs (package-inputs mosquitto)
                    (append sqlite)))
    (native-inputs
     (list googletest pkg-config cunit))))

(define-public protobuf-c-next
  (package
    (inherit protobuf-c)
    (name "protobuf-c")
    (version "1.5.2")
    (source (origin
              (method url-fetch)
              (uri (string-append "https://github.com/protobuf-c/protobuf-c/"
                                  "releases/download/v" version
                                  "/protobuf-c-" version ".tar.gz"))
              (sha256
               (base32
                "090ddnhq0np6skaqnyil713xz80svvwfpxzyb0mwjy9shxqn5j72"))))))

;;; This can be replaced with libnice once this request is merged.
;;; https://codeberg.org/guix/guix/pulls/7920
(define-public libnice-next
  (package
    (inherit libnice)
    (name "libnice")
    (version "0.1.23")
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://gitlab.freedesktop.org/libnice/libnice")
             (commit version)))
       (file-name (git-file-name name version))
       (sha256
        (base32
         "0zqnqhcm1rx5axbzd448yi6j4bq4kykiqb4wihs2p8h1k49nkyjh"))))
    (arguments
     (substitute-keyword-arguments (package-arguments libnice)
       ((#:phases phases)
        #~(modify-phases #$phases
            (replace 'disable-failing-tests
              (lambda _
                (substitute* "tests/meson.build"
                  ;; test-set-port-range.c:66:main:
                  ;; 'nice_agent_gather_candidates (agent, stream1)' should be TRUE
                  (("'test-set-port-range'" all)
                   (string-append "# " all))
                  ;; test-slow-resolving.c:141:start_and_stop_agent_with_slow_resolving:
                  ;; 'nice_agent_gather_candidates (agent, stream_id)' should be TRUE
                  (("^ +'test-slow-resolving'" all)
                   (string-append "# " all))
                  ;; The following test is disabled as it fails in a
                  ;; nondeterministic fashion (see:
                  ;; https://gitlab.freedesktop.org/libnice/libnice/-/issues/151).
                  (("'test-bsd'" all)
                   (string-append "# " all)))
                (substitute* "stun/tests/meson.build"
                  ;; test-bind.c:234: bad_responses: Assertion `len >= 20'
                  ;; failed (see:
                  ;; https://gitlab.freedesktop.org/libnice/libnice/-/issues/150).
                  (("'bind', ")
                   ""))))))))))

;;; This allows calling `guix shell -f guix.scm' in the local repo's root. 
(define vcs-file?
  (if (current-source-directory)
      (git-predicate (dirname (dirname (current-source-directory))))
      (const #t)))

(package
 (inherit dinox)
 (version (string-append %version "-git"))
 (source
  (local-file "../.." "dinox-checkout"
              #:recursive? #t
              #:select? vcs-file?)))

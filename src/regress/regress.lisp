;;;
;;; Regression tests driver.
;;;
;;; We're using SQL EXCEPT to compare what we loaded with what we expected
;;; to load.
;;;

(in-package #:pgloader)

(defun process-regression-test (load-file &key start-logger)
  "Run a regression test for given LOAD-FILE."
  (unless (probe-file load-file)
    (format t "Regression testing ~s: file does not exists." load-file)
    (uiop:quit +os-code-error-regress+))

  ;; now do our work
  (with-monitor (:start-logger start-logger)
    (log-message :log "Regression testing: ~s" load-file)
    (process-command-file load-file)

    ;; once we are done running the load-file, compare the loaded data with
    ;; our expected data file
    (bind ((expected-subdir        (directory-namestring
                                    (asdf:system-relative-pathname
                                     :pgloader "test/regress/expected/")))
           (expected-data-file     (make-pathname :defaults load-file
                                                  :type "out"
                                                  :directory expected-subdir))
           ((target-conn gucs) (parse-target-pg-db-uri load-file))
           (*pg-settings* (pgloader.pgsql:sanitize-user-gucs gucs))
           (*pgsql-reserved-keywords* (list-reserved-keywords target-conn))
           (target-table (create-table (pgconn-table-name target-conn)))

           (expected-data-source
            (parse-source-string-for-type
             :copy (uiop:native-namestring expected-data-file)))

           ;; change target table-name schema
           (expected-data-target
            (let ((e-d-t (clone-connection target-conn)))
              (setf (pgconn-table-name e-d-t)
                    ;;
                    ;; The connection facility still works with cons here,
                    ;; rather than table structure instances, because of
                    ;; depedencies as explained in
                    ;; src/parsers/command-db-uri.lisp
                    ;;
                    (cons "expected" (table-name target-table)))
              e-d-t)))

      (log-message :log "Comparing loaded data against ~s" expected-data-file)

      ;; prepare expected table in "expected" schema
      (with-pgsql-connection (target-conn)
        (with-schema (unqualified-table-name target-table)
          (let* ((tname  (apply-identifier-case unqualified-table-name))
                 (drop   (format nil "drop table if exists expected.~a;"
                                 tname))
                 (create (format nil "create table expected.~a(like ~a);"
                                 tname tname)))
            (log-message :notice "~a" drop)
            (pomo:query drop)
            (log-message :notice "~a" create)
            (pomo:query create))))

      ;; load expected data
      (load-data :from expected-data-source
                 :into expected-data-target
                 :options '(:truncate t)
                 :start-logger nil)

      ;; now compare both
      (with-pgsql-connection (target-conn)
        (with-schema (unqualified-table-name target-table)
          (let* ((tname  (apply-identifier-case unqualified-table-name))
                 (cols (loop :for (name type)
                          :in (list-columns tname)
                          ;;
                          ;; We can't just use table names here, because
                          ;; PostgreSQL support for the POINT datatype fails
                          ;; to implement EXCEPT support, and the query then
                          ;; fails with:
                          ;;
                          ;; could not identify an equality operator for type point
                          ;;
                          :collect (if (string= "point" type)
                                       (format nil "~s::text" name)
                                       (format nil "~s" name))))
                 (sql  (format nil
                               "select count(*) from (select ~{~a~^, ~} from expected.~a except select ~{~a~^, ~} from ~a) ss"
                               cols
                               tname
                               cols
                               tname))
                 (diff-count (pomo:query sql :single)))
            (log-message :notice "~a" sql)
            (log-message :notice "Got a diff of ~a rows" diff-count)
            (if (= 0 diff-count)
                (progn
                  (log-message :log "Regress pass.")
                  #-pgloader-image (values diff-count +os-code-success+)
                  #+pgloader-image (uiop:quit +os-code-success+))
                (progn
                  (log-message :log "Regress fail.")
                  #-pgloader-image (values diff-count +os-code-error-regress+)
                  #+pgloader-image (uiop:quit +os-code-error-regress+)))))))))


;;;
;;; TODO: use the catalogs structures and introspection facilities.
;;;
(defun list-columns (table-name &optional schema)
  "Returns the list of columns for table TABLE-NAME in schema SCHEMA, and
   must be run with an already established PostgreSQL connection."
  (pomo:query (format nil "
    select attname, t.oid::regtype
      from pg_class c
           join pg_namespace n on n.oid = c.relnamespace
           left join pg_attribute a on c.oid = a.attrelid
           join pg_type t on t.oid = a.atttypid
     where c.oid = '~:[~*~a~;~a.~a~]'::regclass and attnum > 0
  order by attnum" schema schema table-name)))

(in-package #:telemetry-protocol)

;;; Protocol primitive = start/end span + events/attributes.
;;; OTLP / Jaeger / LangSmith are backends — not this package.
;;; Logs stay log-protocol. Correlate with :trace-id / :span-id in with-context.

(defclass telemetry-backend () ())

(defun telemetry-backend-p (x)
  (typep x 'telemetry-backend))

(defclass noop-telemetry-backend (telemetry-backend) ())

(defun make-noop-telemetry-backend ()
  (make-instance 'noop-telemetry-backend))

(defvar *telemetry-backend* (make-noop-telemetry-backend)
  "Current backend. Default is no-op so libs can instrument unconditionally.")

(defvar *current-span* nil
  "Innermost TELEMETRY-SPAN, or NIL.")

(defvar *current-trace-id* nil
  "Trace id of *CURRENT-SPAN*, or NIL.")

(defun use-noop-telemetry ()
  (setf *telemetry-backend* (make-noop-telemetry-backend)
        *current-span* nil
        *current-trace-id* nil)
  *telemetry-backend*)

(defun current-span (&optional (backend *telemetry-backend*))
  (declare (ignore backend))
  *current-span*)

(defun current-trace-id (&optional (backend *telemetry-backend*))
  (declare (ignore backend))
  (or *current-trace-id*
      (and *current-span* (telemetry-span-trace-id *current-span*))))

(defun current-span-id (&optional (backend *telemetry-backend*))
  (declare (ignore backend))
  (and *current-span* (telemetry-span-id *current-span*)))

(defun %ensure-backend (&optional (backend *telemetry-backend*))
  (or backend (make-noop-telemetry-backend)))

(defun %parent-span (parent)
  (cond
    ((telemetry-span-p parent) parent)
    ((eq parent :none) nil)
    ((null parent) *current-span*)
    (t (error 'telemetry-error :message (format nil "not a span: ~s" parent)))))

(defgeneric start-span (backend name &key parent attributes kind)
  (:documentation "Start a span named NAME. PARENT is a span, NIL (use *CURRENT-SPAN*),
or :NONE (root). KIND is :internal :client :server. → TELEMETRY-SPAN.")
  (:method ((backend telemetry-backend) name &key parent attributes (kind :internal))
    (let* ((explicit-none (eq parent :none))
           (p (%parent-span parent))
           (span (make-telemetry-span
                  :name (if (stringp name) name (string name))
                  :trace-id (cond
                              (p (telemetry-span-trace-id p))
                              (explicit-none nil)
                              (t *current-trace-id*))
                  :parent-id (and p (telemetry-span-id p))
                  :kind kind
                  :attributes attributes)))
      span))
  (:method ((backend null) name &key parent attributes kind)
    (start-span (%ensure-backend) name :parent parent :attributes attributes
                :kind (or kind :internal))))

(defgeneric end-span (backend span &key status attributes)
  (:documentation "Finish SPAN. STATUS is :ok :error :unset.")
  (:method ((backend telemetry-backend) span &key status attributes)
    (when span
      (when attributes
        (setf (telemetry-span-attributes span)
              (append (telemetry-span-attributes span) (copy-list attributes))))
      (when status
        (setf (telemetry-span-status span) status))
      (unless (telemetry-span-end-internal span)
        (let ((now (get-internal-real-time)))
          (setf (telemetry-span-end-internal span) now
                (telemetry-span-end-unix-ns span)
                (+ (or (telemetry-span-start-unix-ns span) (telemetry-unix-nano))
                   (%duration-ns (or (telemetry-span-start-internal span) now)
                                 now))))))
    span)
  (:method ((backend null) span &key status attributes)
    (end-span (%ensure-backend) span :status status :attributes attributes)))

(defgeneric add-span-event (backend span name &key attributes)
  (:documentation "Append a timed event to SPAN.")
  (:method ((backend telemetry-backend) span name &key attributes)
    (when span
      (push (make-telemetry-event :name (if (stringp name) name (string name))
                                  :attributes attributes)
            (telemetry-span-events span)))
    span)
  (:method ((backend null) span name &key attributes)
    (add-span-event (%ensure-backend) span name :attributes attributes)))

(defgeneric set-span-attribute (backend span key value)
  (:documentation "Set one attribute on SPAN. KEY is a string or keyword.")
  (:method ((backend telemetry-backend) span key value)
    (when span
      (let ((k (if (stringp key) key (string-downcase (string key)))))
        (setf (telemetry-span-attributes span)
              (list* k value
                     (loop for (ak av) on (telemetry-span-attributes span) by #'cddr
                           unless (equal ak k)
                             collect ak and collect av)))))
    span)
  (:method ((backend null) span key value)
    (set-span-attribute (%ensure-backend) span key value)))

(defgeneric record-span-exception (backend span condition &key)
  (:documentation "Mark SPAN :error and record CONDITION as an event.")
  (:method ((backend telemetry-backend) span condition &key)
    (when span
      (setf (telemetry-span-status span) :error)
      (add-span-event backend span "exception"
                      :attributes (list "exception.type"
                                        (string (type-of condition))
                                        "exception.message"
                                        (princ-to-string condition))))
    span)
  (:method ((backend null) span condition &key)
    (record-span-exception (%ensure-backend) span condition)))

(defgeneric record-metric (backend name value &key attributes unit)
  (:documentation "Record a point metric. Wave-1: backends may no-op.")
  (:method ((backend telemetry-backend) name value &key attributes unit)
    (declare (ignore name value attributes unit))
    nil)
  (:method ((backend null) name value &key attributes unit)
    (record-metric (%ensure-backend) name value :attributes attributes :unit unit)))

(defgeneric flush-telemetry (backend &key)
  (:documentation "Export buffered spans/metrics. Default is a no-op.")
  (:method ((backend telemetry-backend) &key)
    backend)
  (:method ((backend null) &key)
    (flush-telemetry (%ensure-backend))))

(defmacro with-span ((name &rest keys &key attributes kind parent
                          (backend '*telemetry-backend*)
                     &allow-other-keys)
                     &body body)
  "Run BODY inside a span. Ends :ok, or :error + exception event on non-local exit.
   Binds *CURRENT-SPAN* / *CURRENT-TRACE-ID*."
  (declare (ignore attributes kind parent))
  (let ((span (gensym "SPAN"))
        (ok (gensym "OK"))
        (be (gensym "BACKEND")))
    `(let* ((,be ,backend)
            (,span (start-span ,be ,name ,@(loop for (k v) on keys by #'cddr
                                                 unless (eq k :backend)
                                                   collect k and collect v)))
            (*current-span* ,span)
            (*current-trace-id* (telemetry-span-trace-id ,span))
            (,ok nil))
       (unwind-protect
            (handler-bind ((error (lambda (c)
                                    (record-span-exception ,be ,span c))))
              (multiple-value-prog1 (progn ,@body)
                (setf ,ok t)))
         (unless (telemetry-span-ended-p ,span)
           (end-span ,be ,span :status (if ,ok :ok :error)))))))

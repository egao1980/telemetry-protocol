(in-package #:telemetry-protocol)

;;; Protocol primitive = start/end span + events/attributes.
;;; OTLP / Jaeger / LangSmith are backends — not this package.
;;; Logs stay log-protocol. Correlate with :trace-id / :span-id in with-context.

(defclass telemetry-backend (tracer-provider) ())

(defun telemetry-backend-p (x)
  (typep x 'telemetry-backend))

(defclass noop-telemetry-backend (telemetry-backend) ())

(defun make-noop-telemetry-backend ()
  (make-instance 'noop-telemetry-backend))

(defvar *telemetry-backend* (make-noop-telemetry-backend)
  "Current backend. Default is no-op so libs can instrument unconditionally.")

(defvar *tracer-provider* nil
  "Instrument registry. NIL means use *TELEMETRY-BACKEND*.")

(defvar *current-span* nil
  "Innermost TELEMETRY-SPAN, or NIL.")

(defvar *current-trace-id* nil
  "Trace id of *CURRENT-SPAN*, or NIL.")

(defvar *redaction-policy* nil
  "When bound to a REDACTION-POLICY, strip secret keys from attributes.
   NIL (default) is a no-op so existing tests stay unchanged.")

(defun current-tracer-provider ()
  (or *tracer-provider* *telemetry-backend* (make-noop-telemetry-backend)))

(defun use-noop-telemetry ()
  (setf *telemetry-backend* (make-noop-telemetry-backend)
        *tracer-provider* nil
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

;;; Redaction — same key set journal / logs / spans share (A6/A7).

(defclass redaction-policy ()
  ((patterns :initarg :patterns
             :accessor redaction-policy-patterns
             :initform '("password" "secret" "authorization" "api-key" "token"))))

(defun redaction-policy-p (x)
  (typep x 'redaction-policy))

(defun make-default-redaction-policy (&key patterns)
  (make-instance 'redaction-policy
                 :patterns (or patterns
                               '("password" "secret" "authorization"
                                 "api-key" "token"))))

(defun %effective-redaction-policy (&optional provider)
  (or *redaction-policy*
      (and provider (tracer-provider-p provider)
           (tracer-provider-redaction-policy provider))))

(defun %attribute-key-string (key)
  (cond
    ((stringp key) key)
    ((null key) "")
    ((symbolp key) (string-downcase (symbol-name key)))
    (t (princ-to-string key))))

(defun %key-segments (key)
  (let ((s (string-downcase (%attribute-key-string key))))
    (loop for start = 0 then (1+ pos)
          for pos = (position-if (lambda (c) (member c '(#\. #\- #\_)))
                                 s :start start)
          collect (subseq s start (or pos (length s)))
          while pos)))

(defun %secret-attribute-key-p (key patterns)
  "Match password/secret/authorization/api-key/token without eating input_tokens."
  (let* ((raw (string-downcase (%attribute-key-string key)))
         (dashed (substitute #\- #\_ raw))
         (segments (%key-segments raw)))
    (some (lambda (pattern)
            (let ((p (string-downcase (substitute #\- #\_ pattern))))
              (cond
                ((string= p "token")
                 (or (string= dashed "token")
                     (member "token" segments :test #'string=)))
                ((string= p "api-key")
                 (or (search "api-key" dashed)
                     (and (member "api" segments :test #'string=)
                          (member "key" segments :test #'string=))))
                (t
                 (or (string= dashed p)
                     (search p dashed)
                     (member p segments :test #'string=))))))
          patterns)))

(defgeneric redact-attributes (policy attributes)
  (:documentation "PLIST in, PLIST out. NIL policy is identity.")
  (:method ((policy null) attributes)
    attributes)
  (:method ((policy redaction-policy) attributes)
    (loop for (k v) on attributes by #'cddr
          unless (%secret-attribute-key-p k (redaction-policy-patterns policy))
            collect k and collect v)))

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
                                  :attributes (redact-attributes
                                               (%effective-redaction-policy backend)
                                               attributes))
            (telemetry-span-events span)))
    span)
  (:method ((backend null) span name &key attributes)
    (add-span-event (%ensure-backend) span name :attributes attributes)))

(defgeneric set-span-attribute (backend span key value)
  (:documentation "Set one attribute on SPAN. KEY is a string or keyword.")
  (:method ((backend telemetry-backend) span key value)
    (when span
      (let* ((k (if (stringp key) key (string-downcase (string key))))
             (pair (redact-attributes (%effective-redaction-policy backend)
                                      (list k value))))
        (when pair
          (let ((rk (first pair))
                (rv (second pair)))
            (setf (telemetry-span-attributes span)
                  (list* rk rv
                         (loop for (ak av) on (telemetry-span-attributes span) by #'cddr
                               unless (equal ak rk)
                                 collect ak and collect av)))))))
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

(defun %instrument-name (name)
  (cond
    ((stringp name) name)
    ((keywordp name) (string-downcase (symbol-name name)))
    ((symbolp name) (string-downcase (symbol-name name)))
    (t (princ-to-string name))))

(defun %normalize-instrument-kind (kind)
  (let ((k (cond
             ((keywordp kind) kind)
             ((symbolp kind)
              (intern (symbol-name kind) :keyword))
             (t nil))))
    (unless (member k '(:counter :up-down-counter :gauge :histogram) :test #'eq)
      (error 'telemetry-error
             :message (format nil "unknown instrument kind: ~s" kind)))
    k))

(defun %instrument-class (kind)
  (ecase kind
    (:counter 'counter)
    (:up-down-counter 'up-down-counter)
    (:gauge 'gauge)
    (:histogram 'histogram)))

(defgeneric get-instrument (provider name kind &key unit description boundaries)
  (:documentation "Create-or-return an instrument named NAME of KIND
(:counter :up-down-counter :gauge :histogram) on PROVIDER.")
  (:method ((provider tracer-provider) name kind &key unit description boundaries)
    (let* ((iname (%instrument-name name))
           (ikind (%normalize-instrument-kind kind))
           (existing (gethash iname (tracer-provider-instruments provider))))
      (cond
        (existing
         (unless (eq ikind (telemetry-instrument-kind existing))
           (restart-case
               (error 'telemetry-error
                      :message (format nil "instrument ~s is ~s, not ~s"
                                       iname
                                       (telemetry-instrument-kind existing)
                                       ikind))
             (use-value (value)
               :report "Use a supplied instrument"
               (return-from get-instrument value))))
         existing)
        (t
         (let ((inst (apply #'make-instance (%instrument-class ikind)
                            :name iname
                            :kind ikind
                            :unit unit
                            :description description
                            :provider provider
                            (when (eq ikind :histogram)
                              (list :boundaries (copy-list boundaries))))))
           (setf (gethash iname (tracer-provider-instruments provider)) inst)
           inst)))))
  (:method ((provider null) name kind &key unit description boundaries)
    (get-instrument (current-tracer-provider) name kind
                    :unit unit :description description :boundaries boundaries)))

(defgeneric record-instrument (backend instrument value &key attributes)
  (:documentation "Backend hook for RECORD. Default is a no-op.")
  (:method ((backend telemetry-backend) instrument value &key attributes)
    (declare (ignore instrument value attributes))
    nil)
  (:method ((backend null) instrument value &key attributes)
    (record-instrument (%ensure-backend) instrument value :attributes attributes)))

(defgeneric record (instrument value &key attributes)
  (:documentation "Record VALUE on INSTRUMENT. Counter/histogram add; gauge set;
up-down-counter accepts signed values. No in-process aggregation.")
  (:method ((instrument telemetry-instrument) value &key attributes)
    (let* ((provider (or (telemetry-instrument-provider instrument)
                         (current-tracer-provider)))
           (attrs (redact-attributes (%effective-redaction-policy provider)
                                     attributes)))
      (record-instrument provider instrument value :attributes attrs))))

(defgeneric record-metric (backend name value &key attributes unit)
  (:documentation "Convenience: record VALUE on a counter named NAME.")
  (:method ((backend telemetry-backend) name value &key attributes unit)
    (record (get-instrument backend name :counter :unit unit)
            value :attributes attributes))
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

(defun instrument-gen-ai-span (span &key operation-name request-model
                               response-model response-id
                               input-tokens output-tokens
                               tool-name agent-name
                               (backend *telemetry-backend*))
  "Set gen_ai.* attributes on SPAN. Used by llm/agent/task instrumentation."
  (when span
    (flet ((set-attr (key value)
             (when value
               (set-span-attribute backend span key value))))
      (set-attr +gen-ai-operation-name+ operation-name)
      (set-attr +gen-ai-request-model+ request-model)
      (set-attr +gen-ai-response-model+ response-model)
      (set-attr +gen-ai-response-id+ response-id)
      (set-attr +gen-ai-usage-input-tokens+ input-tokens)
      (set-attr +gen-ai-usage-output-tokens+ output-tokens)
      (set-attr +gen-ai-tool-name+ tool-name)
      (set-attr +gen-ai-agent-name+ agent-name)))
  span)

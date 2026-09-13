(in-package #:telemetry-protocol)

;;; OTel GenAI semantic-convention keys (string names on the wire).
;;; Libs set these as attribute keys; backends may remap.

(defparameter +gen-ai-operation-name+ "gen_ai.operation.name")
(defparameter +gen-ai-request-model+ "gen_ai.request.model")
(defparameter +gen-ai-response-model+ "gen_ai.response.model")
(defparameter +gen-ai-response-id+ "gen_ai.response.id")
(defparameter +gen-ai-usage-input-tokens+ "gen_ai.usage.input_tokens")
(defparameter +gen-ai-usage-output-tokens+ "gen_ai.usage.output_tokens")
(defparameter +gen-ai-tool-name+ "gen_ai.tool.name")
(defparameter +gen-ai-agent-name+ "gen_ai.agent.name")

(defconstant +unix-epoch-universal+ 2208988800)

(defun telemetry-unix-nano ()
  "Unix time in nanoseconds. Second resolution + internal-real-time remainder."
  (let* ((sec (- (get-universal-time) +unix-epoch-universal+))
         (frac (mod (get-internal-real-time) internal-time-units-per-second)))
    (+ (* sec 1000000000)
       (floor (* frac 1000000000) internal-time-units-per-second))))

(defun %duration-ns (start-internal end-internal)
  (max 0 (floor (* (- end-internal start-internal) 1000000000)
                internal-time-units-per-second)))

(defun %hex-id (nbytes)
  (with-output-to-string (s)
    (loop repeat nbytes
          do (format s "~2,'0x" (random 256)))))

(defclass telemetry-span ()
  ((name :initarg :name :accessor telemetry-span-name)
   (trace-id :initarg :trace-id :accessor telemetry-span-trace-id)
   (span-id :initarg :span-id :accessor telemetry-span-id)
   (parent-id :initarg :parent-id :accessor telemetry-span-parent-id :initform nil)
   (kind :initarg :kind :accessor telemetry-span-kind :initform :internal)
   (attributes :initarg :attributes :accessor telemetry-span-attributes
               :initform nil)
   (events :initarg :events :accessor telemetry-span-events :initform nil)
   (status :initarg :status :accessor telemetry-span-status :initform :unset)
   (start-internal :initarg :start-internal :accessor telemetry-span-start-internal
                   :initform (get-internal-real-time))
   (end-internal :initarg :end-internal :accessor telemetry-span-end-internal
                 :initform nil)
   (start-unix-ns :initarg :start-unix-ns :accessor telemetry-span-start-unix-ns
                  :initform nil)
   (end-unix-ns :initarg :end-unix-ns :accessor telemetry-span-end-unix-ns
                :initform nil)))

(defun make-telemetry-span (&key name trace-id span-id parent-id (kind :internal)
                              attributes)
  (make-instance 'telemetry-span
                 :name name
                 :trace-id (or trace-id (%hex-id 16))
                 :span-id (or span-id (%hex-id 8))
                 :parent-id parent-id
                 :kind kind
                 :attributes (copy-list attributes)
                 :start-internal (get-internal-real-time)
                 :start-unix-ns (telemetry-unix-nano)))

(defun telemetry-span-p (x)
  (typep x 'telemetry-span))

(defun telemetry-span-ended-p (span)
  (and span (telemetry-span-end-internal span)))

(defclass telemetry-event ()
  ((name :initarg :name :accessor telemetry-event-name)
   (attributes :initarg :attributes :accessor telemetry-event-attributes :initform nil)
   (time-internal :initarg :time-internal :accessor telemetry-event-time-internal
                  :initform (get-internal-real-time))
   (time-unix-ns :initarg :time-unix-ns :accessor telemetry-event-time-unix-ns
                 :initform nil)))

(defun make-telemetry-event (&key name attributes)
  (make-instance 'telemetry-event
                 :name name
                 :attributes (copy-list attributes)
                 :time-internal (get-internal-real-time)
                 :time-unix-ns (telemetry-unix-nano)))

(defun telemetry-event-p (x)
  (typep x 'telemetry-event))

(defclass telemetry-metric ()
  ((name :initarg :name :accessor telemetry-metric-name)
   (value :initarg :value :accessor telemetry-metric-value)
   (unit :initarg :unit :accessor telemetry-metric-unit :initform nil)
   (attributes :initarg :attributes :accessor telemetry-metric-attributes
               :initform nil)
   (kind :initarg :kind :accessor telemetry-metric-kind :initform nil)
   (boundaries :initarg :boundaries :accessor telemetry-metric-boundaries
               :initform nil)))

(defun make-telemetry-metric (&key name value unit attributes kind boundaries)
  (make-instance 'telemetry-metric
                 :name name :value value :unit unit
                 :attributes (copy-list attributes)
                 :kind kind
                 :boundaries (copy-list boundaries)))

(defun telemetry-metric-p (x)
  (typep x 'telemetry-metric))

;;; Tracer provider + metrics instruments (no views / aggregation).

(defclass tracer-provider ()
  ((instruments :initform (make-hash-table :test 'equal)
                :accessor tracer-provider-instruments)
   (redaction-policy :initarg :redaction-policy
                     :initform nil
                     :accessor tracer-provider-redaction-policy))
  (:documentation "Instrument registry. TELEMETRY-BACKEND is a provider."))

(defun tracer-provider-p (x)
  (typep x 'tracer-provider))

(defclass telemetry-instrument ()
  ((name :initarg :name :accessor telemetry-instrument-name)
   (kind :initarg :kind :accessor telemetry-instrument-kind)
   (unit :initarg :unit :accessor telemetry-instrument-unit :initform nil)
   (description :initarg :description :accessor telemetry-instrument-description
                :initform nil)
   (provider :initarg :provider :accessor telemetry-instrument-provider
             :initform nil)))

(defun telemetry-instrument-p (x)
  (typep x 'telemetry-instrument))

(defclass counter (telemetry-instrument) ())

(defun counter-p (x)
  (typep x 'counter))

(defclass up-down-counter (telemetry-instrument) ())

(defun up-down-counter-p (x)
  (typep x 'up-down-counter))

(defclass gauge (telemetry-instrument) ())

(defun gauge-p (x)
  (typep x 'gauge))

(defclass histogram (telemetry-instrument)
  ((boundaries :initarg :boundaries :accessor histogram-boundaries
               :initform nil)))

(defun histogram-p (x)
  (typep x 'histogram))

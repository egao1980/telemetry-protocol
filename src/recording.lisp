(in-package #:telemetry-protocol)

;;; In-process sink for tests and local dumps. Not OTLP.

(defclass recording-telemetry-backend (telemetry-backend)
  ((spans :initform nil :accessor recorded-spans)
   (metrics :initform nil :accessor recorded-metrics)))

(defun make-recording-telemetry-backend ()
  (make-instance 'recording-telemetry-backend))

(defun use-recording-telemetry ()
  (setf *telemetry-backend* (make-recording-telemetry-backend)
        *tracer-provider* nil
        *current-span* nil
        *current-trace-id* nil)
  *telemetry-backend*)

(defun clear-telemetry (&optional (backend *telemetry-backend*))
  (when (typep backend 'recording-telemetry-backend)
    (setf (recorded-spans backend) nil
          (recorded-metrics backend) nil))
  backend)

(defmethod end-span :after ((backend recording-telemetry-backend) span
                            &key status attributes)
  (declare (ignore status attributes))
  (when (and span (telemetry-span-ended-p span)
             (not (find span (recorded-spans backend))))
    (push span (recorded-spans backend))))

(defmethod record-instrument ((backend recording-telemetry-backend) instrument value
                              &key attributes)
  (let ((m (make-telemetry-metric
            :name (telemetry-instrument-name instrument)
            :value value
            :unit (telemetry-instrument-unit instrument)
            :attributes attributes
            :kind (telemetry-instrument-kind instrument)
            :boundaries (and (histogram-p instrument)
                             (histogram-boundaries instrument)))))
    (push m (recorded-metrics backend))
    m))

(in-package #:telemetry-protocol)

;;; In-process sink for tests and local dumps. Not OTLP.

(defclass recording-telemetry-backend (telemetry-backend)
  ((spans :initform nil :accessor recorded-spans)
   (metrics :initform nil :accessor recorded-metrics)))

(defun make-recording-telemetry-backend ()
  (make-instance 'recording-telemetry-backend))

(defun use-recording-telemetry ()
  (setf *telemetry-backend* (make-recording-telemetry-backend)
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

(defmethod record-metric ((backend recording-telemetry-backend) name value
                          &key attributes unit)
  (let ((m (make-telemetry-metric :name (if (stringp name) name (string name))
                                  :value value :unit unit
                                  :attributes attributes)))
    (push m (recorded-metrics backend))
    m))

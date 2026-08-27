(in-package #:telemetry-protocol)

(define-condition telemetry-error (error)
  ((message :initarg :message :reader telemetry-error-message :initform nil))
  (:report (lambda (c s)
             (format s "telemetry error~@[: ~a~]" (telemetry-error-message c)))))

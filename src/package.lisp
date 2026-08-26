(defpackage #:telemetry-protocol
  (:use #:cl)
  (:nicknames #:stack-telemetry)
  (:export
   #:telemetry-error
   #:telemetry-error-message

   #:telemetry-backend
   #:telemetry-backend-p
   #:noop-telemetry-backend
   #:make-noop-telemetry-backend
   #:recording-telemetry-backend
   #:make-recording-telemetry-backend
   #:recorded-spans
   #:recorded-metrics
   #:clear-telemetry

   #:*telemetry-backend*
   #:*current-span*
   #:*current-trace-id*

   #:telemetry-span
   #:make-telemetry-span
   #:telemetry-span-p
   #:telemetry-span-name
   #:telemetry-span-trace-id
   #:telemetry-span-id
   #:telemetry-span-parent-id
   #:telemetry-span-kind
   #:telemetry-span-attributes
   #:telemetry-span-events
   #:telemetry-span-status
   #:telemetry-span-start-internal
   #:telemetry-span-end-internal
   #:telemetry-span-start-unix-ns
   #:telemetry-span-end-unix-ns
   #:telemetry-span-ended-p
   #:telemetry-unix-nano

   #:telemetry-event
   #:make-telemetry-event
   #:telemetry-event-p
   #:telemetry-event-name
   #:telemetry-event-attributes
   #:telemetry-event-time-internal
   #:telemetry-event-time-unix-ns

   #:telemetry-metric
   #:make-telemetry-metric
   #:telemetry-metric-p
   #:telemetry-metric-name
   #:telemetry-metric-value
   #:telemetry-metric-unit
   #:telemetry-metric-attributes

   #:start-span
   #:end-span
   #:add-span-event
   #:set-span-attribute
   #:record-span-exception
   #:record-metric
   #:flush-telemetry
   #:current-span
   #:current-trace-id
   #:current-span-id
   #:with-span
   #:use-recording-telemetry
   #:use-noop-telemetry

   #:+gen-ai-operation-name+
   #:+gen-ai-request-model+
   #:+gen-ai-response-model+
   #:+gen-ai-response-id+
   #:+gen-ai-usage-input-tokens+
   #:+gen-ai-usage-output-tokens+
   #:+gen-ai-tool-name+
   #:+gen-ai-agent-name+))

(in-package #:telemetry-protocol)

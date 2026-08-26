(in-package #:telemetry-protocol/tests)

(deftest noop-does-not-error
  (use-noop-telemetry)
  (with-span ("chat" :attributes (list +gen-ai-request-model+ "mock"))
    (ok (telemetry-span-p *current-span*))
    (ok (stringp (current-trace-id)))
    (set-span-attribute *telemetry-backend* *current-span*
                        +gen-ai-usage-input-tokens+ 3)
    (add-span-event *telemetry-backend* *current-span* "first-token"))
  (ok (null *current-span*)))

(defun %span (spans name)
  (find name spans :key #'telemetry-span-name :test #'equal))

(deftest recording-nests-and-records
  (let ((b (use-recording-telemetry)))
    (with-span ("agent")
      (with-span ("generate" :kind :client
                  :attributes (list +gen-ai-operation-name+ "chat"))
        (set-span-attribute b *current-span* +gen-ai-request-model+ "mock")
        (add-span-event b *current-span* "first-token"))
      (with-span ("tool" :attributes (list +gen-ai-tool-name+ "sum"))
        nil))
    (let* ((spans (recorded-spans b))
           (agent (%span spans "agent"))
           (gen (%span spans "generate"))
           (tool (%span spans "tool")))
      (ok (= 3 (length spans)))
      (ok agent)
      (ok gen)
      (ok tool)
      (ok (equal (telemetry-span-trace-id tool)
                 (telemetry-span-trace-id agent)))
      (ok (equal (telemetry-span-id agent)
                 (telemetry-span-parent-id tool)))
      (ok (eq :client (telemetry-span-kind gen)))
      (ok (equal "mock" (getf (telemetry-span-attributes gen)
                              +gen-ai-request-model+)))
      (ok (equal "first-token"
                 (telemetry-event-name
                  (first (telemetry-span-events gen)))))
      (ok (eq :ok (telemetry-span-status tool))))))

(deftest recording-exception-marks-error
  (let ((b (use-recording-telemetry)))
    (handler-case
        (with-span ("boom")
          (error "nope"))
      (error ()))
    (let ((span (first (recorded-spans b))))
      (ok (eq :error (telemetry-span-status span)))
      (ok (equal "exception"
                 (telemetry-event-name (first (telemetry-span-events span))))))))

(deftest record-metric-recording
  (let ((b (use-recording-telemetry)))
    (record-metric b "gen_ai.client.token.usage" 12
                   :unit "token"
                   :attributes (list +gen-ai-request-model+ "mock"))
    (ok (= 1 (length (recorded-metrics b))))
    (ok (equal "gen_ai.client.token.usage"
               (telemetry-metric-name (first (recorded-metrics b)))))))

(deftest parent-none-starts-new-trace
  (let ((b (use-recording-telemetry)))
    (with-span ("outer")
      (let ((outer-id (current-trace-id)))
        (with-span ("other" :parent :none)
          (ok (not (equal outer-id (current-trace-id)))))
        (ok (equal outer-id (current-trace-id)))))
    (ok (= 2 (length (recorded-spans b))))))

(deftest span-unix-ns-set-on-end
  (let ((b (use-recording-telemetry)))
    (with-span ("timed")
      (ok (integerp (telemetry-span-start-unix-ns *current-span*)))
      (ok (plusp (telemetry-span-start-unix-ns *current-span*)))
      (add-span-event b *current-span* "tick"))
    (let* ((span (first (recorded-spans b)))
           (ev (first (telemetry-span-events span))))
      (ok (integerp (telemetry-span-end-unix-ns span)))
      (ok (>= (telemetry-span-end-unix-ns span)
              (telemetry-span-start-unix-ns span)))
      (ok (integerp (telemetry-event-time-unix-ns ev)))
      (ok (plusp (telemetry-event-time-unix-ns ev))))))

(deftest flush-telemetry-noop-on-recording
  (let ((b (use-recording-telemetry)))
    (with-span ("x") nil)
    (ok (eq b (flush-telemetry b)))
    (ok (= 1 (length (recorded-spans b))))))

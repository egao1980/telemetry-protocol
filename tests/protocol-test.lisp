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

(defun %metric (metrics name)
  (find name metrics :key #'telemetry-metric-name :test #'equal))

(defun %attr (plist key)
  (loop for (k v) on plist by #'cddr
        when (equal k key) return v))

(deftest instrument-registry-create-or-return
  (let ((b (use-recording-telemetry)))
    (let ((c1 (get-instrument b "hits" :counter :unit "1" :description "hits"))
          (c2 (get-instrument b "hits" :counter)))
      (ok (eq c1 c2))
      (ok (counter-p c1))
      (ok (equal "hits" (telemetry-instrument-name c1)))
      (ok (eq :counter (telemetry-instrument-kind c1)))
      (ok (equal "1" (telemetry-instrument-unit c1)))
      (let ((g (get-instrument b "temp" :gauge)))
        (ok (gauge-p g))
        (ok (not (eq c1 g))))
      (ok (signals (get-instrument b "hits" :gauge) 'telemetry-error))
      (let ((other (get-instrument b "other" :histogram)))
        (ok (eq other
                (handler-bind ((telemetry-error
                                (lambda (c) (use-value other c))))
                  (get-instrument b "hits" :histogram))))))))

(deftest counter-gauge-histogram-record
  (let ((b (use-recording-telemetry)))
    (let ((c (get-instrument b "c" :counter :unit "1"))
          (g (get-instrument b "g" :gauge))
          (u (get-instrument b "u" :up-down-counter))
          (h (get-instrument b "h" :histogram :boundaries '(0.5 1.0 5.0))))
      (record c 1 :attributes (list "route" "/"))
      (record g 42)
      (record u -3)
      (record h 0.7)
      (ok (= 4 (length (recorded-metrics b))))
      (let ((cm (%metric (recorded-metrics b) "c"))
            (gm (%metric (recorded-metrics b) "g"))
            (um (%metric (recorded-metrics b) "u"))
            (hm (%metric (recorded-metrics b) "h")))
        (ok (eq :counter (telemetry-metric-kind cm)))
        (ok (= 1 (telemetry-metric-value cm)))
        (ok (equal "/" (%attr (telemetry-metric-attributes cm) "route")))
        (ok (eq :gauge (telemetry-metric-kind gm)))
        (ok (= 42 (telemetry-metric-value gm)))
        (ok (eq :up-down-counter (telemetry-metric-kind um)))
        (ok (= -3 (telemetry-metric-value um)))
        (ok (eq :histogram (telemetry-metric-kind hm)))
        (ok (= 0.7 (telemetry-metric-value hm)))
        (ok (equal '(0.5 1.0 5.0) (telemetry-metric-boundaries hm)))
        (ok (equal '(0.5 1.0 5.0) (histogram-boundaries h)))))))

(deftest histogram-stores-boundaries
  (let* ((b (use-recording-telemetry))
         (h (get-instrument b "latency" :histogram :boundaries '(1 5 10))))
    (ok (histogram-p h))
    (ok (equal '(1 5 10) (histogram-boundaries h)))
    (record h 4)
    (ok (equal '(1 5 10)
               (telemetry-metric-boundaries (first (recorded-metrics b)))))))

(deftest redaction-strips-secret-attributes
  (let ((*redaction-policy* (make-default-redaction-policy))
        (b (use-recording-telemetry)))
    (with-span ("s")
      (set-span-attribute b *current-span* "password" "hunter2")
      (set-span-attribute b *current-span* "user" "nik")
      (set-span-attribute b *current-span* "authorization" "Bearer x")
      (set-span-attribute b *current-span* "api-key" "sk")
      (set-span-attribute b *current-span* "access-token" "t")
      (add-span-event b *current-span* "login"
                      :attributes (list "secret" "s" "ok" t)))
    (let* ((span (first (recorded-spans b)))
           (attrs (telemetry-span-attributes span))
           (ev (first (telemetry-span-events span))))
      (ok (null (%attr attrs "password")))
      (ok (null (%attr attrs "authorization")))
      (ok (null (%attr attrs "api-key")))
      (ok (null (%attr attrs "access-token")))
      (ok (equal "nik" (%attr attrs "user")))
      (ok (null (%attr (telemetry-event-attributes ev) "secret")))
      (ok (eq t (%attr (telemetry-event-attributes ev) "ok"))))
    (record (get-instrument b "c" :counter) 1
            :attributes (list "api_key" "sk" "route" "/"
                              +gen-ai-usage-input-tokens+ 3))
    (let ((attrs (telemetry-metric-attributes (first (recorded-metrics b)))))
      (ok (null (%attr attrs "api_key")))
      (ok (equal "/" (%attr attrs "route")))
      (ok (= 3 (%attr attrs +gen-ai-usage-input-tokens+))))))

(deftest record-metric-hits-named-counter
  (let ((b (use-recording-telemetry)))
    (record-metric b "gen_ai.client.token.usage" 12 :unit "token")
    (ok (eq :counter (telemetry-metric-kind (first (recorded-metrics b)))))
    (ok (eq (get-instrument b "gen_ai.client.token.usage" :counter)
            (get-instrument b "gen_ai.client.token.usage" :counter)))))

(deftest instrument-gen-ai-span-sets-attributes
  (let ((b (use-recording-telemetry)))
    (with-span ("chat")
      (instrument-gen-ai-span *current-span*
                              :operation-name "chat"
                              :request-model "mock"
                              :input-tokens 3
                              :output-tokens 8
                              :backend b))
    (let ((attrs (telemetry-span-attributes (first (recorded-spans b)))))
      (ok (equal "chat" (%attr attrs +gen-ai-operation-name+)))
      (ok (equal "mock" (%attr attrs +gen-ai-request-model+)))
      (ok (= 3 (%attr attrs +gen-ai-usage-input-tokens+)))
      (ok (= 8 (%attr attrs +gen-ai-usage-output-tokens+))))))

(defsystem "telemetry-protocol"
  :version "0.1.0"
  :description "CLOS telemetry protocol (traces/spans + thin metrics) for cl-stack"
  :author "egao1980"
  :license "MIT"
  :depends-on ()
  :serial t
  :pathname "src"
  :components ((:file "package")
               (:file "conditions")
               (:file "types")
               (:file "protocol")
               (:file "recording"))
  :in-order-to ((test-op (test-op "telemetry-protocol/tests"))))

(defsystem "telemetry-protocol/tests"
  :depends-on ("telemetry-protocol" "rove")
  :pathname "tests"
  :serial t
  :components ((:file "package")
               (:file "protocol-test"))
  :perform (test-op (o c)
             (unless (symbol-call :rove :run c)
               (error "tests failed for ~A" (component-name c)))))

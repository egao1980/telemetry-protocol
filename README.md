# telemetry-protocol

CLOS **traces / spans** (+ thin metrics) for [cl-stack](https://github.com/egao1980/cl-stack). Not logging — that's [`log-protocol`](https://github.com/egao1980/log-protocol).

**Protocol owns:** span lifecycle, current context, attribute/event/exception GFs, metric GF, `flush-telemetry`.  
**Product backends are separate repos.** In-tree: **noop** (default) and **recording** (test sink). OTLP/HTTP JSON is [`telemetry-backend-otlp`](https://github.com/egao1980/telemetry-backend-otlp) — do not add exporters here.

Libs call `with-span` unconditionally. Default backend is a no-op.

```lisp
(asdf:load-system "telemetry-protocol")
(stack-telemetry:use-recording-telemetry)
(stack-telemetry:with-span ("invoke_agent"
                            :attributes (list stack-telemetry:+gen-ai-agent-name+ "researcher"))
  (stack-telemetry:with-span ("chat" :kind :client
                            :attributes (list stack-telemetry:+gen-ai-request-model+ "mock"))
    (stack-telemetry:set-span-attribute
     stack-telemetry:*telemetry-backend* stack-telemetry:*current-span*
     stack-telemetry:+gen-ai-usage-output-tokens+ 32)))
(length (stack-telemetry:recorded-spans stack-telemetry:*telemetry-backend*))
```

Correlate logs: put `trace-id` / `span-id` in `log-protocol:with-context` (`current-trace-id` / `current-span-id`). Do **not** emit spans through `log-protocol`.

Attribute names follow [OTel GenAI](https://opentelemetry.io/docs/specs/semconv/gen-ai/) (`gen_ai.*` constants exported). Spans carry `start-unix-ns` / `end-unix-ns` for exporters. `flush-telemetry` is a no-op on noop/recording.

## License

MIT — see [LICENSE](LICENSE).

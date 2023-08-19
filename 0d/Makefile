ODIN ?= odin

.PHONY: check
check:
	$(ODIN) check rt -no-entry-point
	$(ODIN) check interpreter -no-entry-point
	$(ODIN) check examples/file_writer

.PHONY: test
test:
	$(ODIN) test rt
	$(ODIN) test interpreter

interpreter.bin: \
	interpreter/interpreter.odin \
	interpreter/drawio_mxgraph.odin \
	interpreter/cli.odin

	$(ODIN) build interpreter -show-timings -debug

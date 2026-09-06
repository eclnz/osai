ODIN ?= odin
BIN  := bin/osai
SRC  := src

.PHONY: all build run headless test check bench bench-build bench-accept fmt clean

all: build

build:
	@mkdir -p bin
	$(ODIN) build $(SRC) -out:$(BIN) -vet

release:
	@mkdir -p bin
	$(ODIN) build $(SRC) -out:$(BIN) -vet -o:speed -disable-assert -no-bounds-check

run: build
	./$(BIN)

# The simulation does not need a window: same fixed step, scripted intent.
headless: build
	./$(BIN) --headless --ticks=600

test:
	$(ODIN) test tests

# Type-check every package without producing a binary.
check:
	$(ODIN) check $(SRC) -vet
	$(ODIN) check $(SRC)/ecs -no-entry-point -vet
	$(ODIN) check $(SRC)/serial -no-entry-point -vet
	$(ODIN) check $(SRC)/world -no-entry-point -vet
	$(ODIN) check $(SRC)/sim -no-entry-point -vet
	$(ODIN) check $(SRC)/render -no-entry-point -vet
	$(ODIN) check $(SRC)/devtools -no-entry-point -vet
	@$(MAKE) --no-print-directory bench

# Benchmarking. Built with the release flags and to its own binary, so that a
# measurement is never taken against a debug build or against whatever `make
# build` last left in bin/.
BENCH_BIN := bin/osai-bench

bench-build:
	@mkdir -p bin
	@$(ODIN) build $(SRC) -out:$(BENCH_BIN) -o:speed -disable-assert -no-bounds-check

# Compares against bench/baseline.json and fails on a real regression.
bench: bench-build
	@python3 tools/bench.py

# Record the current numbers as the baseline. Do this in the same commit as
# whatever changed the cost, so the baseline always describes the tree it is in.
bench-accept: bench-build
	@python3 tools/bench.py --accept

fmt:
	$(ODIN) fmt $(SRC) tests

clean:
	rm -rf bin save.bin

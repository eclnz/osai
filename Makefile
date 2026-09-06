ODIN ?= odin
BIN  := bin/osai
SRC  := src

.PHONY: all build run headless test check fmt clean

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
	$(ODIN) check $(SRC)/world -no-entry-point -vet
	$(ODIN) check $(SRC)/sim -no-entry-point -vet
	$(ODIN) check $(SRC)/render -no-entry-point -vet

fmt:
	$(ODIN) fmt $(SRC) tests

clean:
	rm -rf bin save.bin

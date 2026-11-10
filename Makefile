ODIN  ?= odin
FLAGS ?= -o:speed
SRC   := main.odin media.odin search.odin

loopmin: $(SRC)
	$(ODIN) build . -out:loopmin $(FLAGS)

debug: $(SRC)
	$(ODIN) build . -out:loopmin -debug

test: loopmin
	./test.sh

clean:
	rm -f loopmin

.PHONY: debug test clean

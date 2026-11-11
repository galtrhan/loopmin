ODIN   ?= odin
FLAGS  ?= -o:speed
PREFIX ?= /usr/local
SRC    := main.odin media.odin search.odin

loopmin: $(SRC)
	$(ODIN) build . -out:loopmin $(FLAGS)

debug: $(SRC)
	$(ODIN) build . -out:loopmin -debug

test: loopmin
	./test.sh

install: loopmin
	install -d "$(DESTDIR)$(PREFIX)/bin"
	install -m 755 loopmin "$(DESTDIR)$(PREFIX)/bin/loopmin"

clean:
	rm -f loopmin

.PHONY: debug test install clean

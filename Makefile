IMAGE   = ovrclk/test-runner
SHELL		= /bin/sh
PREFIX	= /usr/local
SOURCES	= test-runner.bash
PROGRAM = test-runner

execdir=$(PREFIX)/bin

all: $(PROGRAM)

$(PROGRAM): $(SOURCES)
	rm -rf $@
	cat $(SOURCES) > $@+
	bash -n $@+
	mv $@+ $@
	chmod 0755 $@

install: $(PROGRAM)
	install -d "$(execdir)"
	install -m 0755 $(PROGRAM) "$(execdir)/$(PROGRAM)"

run: all
	./$(PROGRAM)

uninstall:
	rm -f "$(execdir)/$(PROGRAM)"

image:
	docker build -t $(IMAGE) image

clean:
	rm -f $(PROGRAM)

.PHONY: run install uninstall clean image

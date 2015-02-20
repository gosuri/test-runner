IMAGE   = ovrclk/test-runner
SHELL   = /bin/sh
PREFIX  = /usr/local
SOURCES	= test-runner.bash
PROGRAM = test-runner
RUBIES  = 2.1.2 jruby-1.7.9

execdir=$(PREFIX)/bin

default: $(PROGRAM)

$(PROGRAM): $(SOURCES)
	rm -rf $@
	cat $(SOURCES) > $@+
	bash -n $@+
	mv $@+ $@
	chmod 0755 $@

install: $(PROGRAM)
	install -d "$(execdir)"
	install -m 0755 $(PROGRAM) "$(execdir)/$(PROGRAM)"

all: $(PROGRAM) $(RUBIES) 
	./$(PROGRAM) --version

uninstall:
	rm -f "$(execdir)/$(PROGRAM)"

image: $(PROGRAM)
	@image/base-image

$(RUBIES):
	@image/ruby-image $@

rubies: $(RUBIES)

clean:
	rm -f $(PROGRAM)

publish:
	docker push $(IMAGE)
	@$(foreach img, $(RUBIES), docker push $(img);)


.PHONY: $(PROGRAM) $(RUBIES) rubies all run install uninstall clean image

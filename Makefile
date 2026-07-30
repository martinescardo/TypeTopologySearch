TT ?=
E ?=
TYPETOPOLOGY ?= $(if $(TT),$(TT),$(HOME)/TypeTopology)
EMACSDIR ?= $(if $(E),$(E),$(HOME)/.emacs.d)

.PHONY: all search-page definitions agda-input-dump compile install

all: search-page definitions agda-input-dump compile

search-page:
	./generate-search-page $(TYPETOPOLOGY)

definitions:
	./generate-definitions $(TYPETOPOLOGY)

agda-input-dump:
	./generate-agda-input-dump

compile:
	./compile-emacs-command

install: compile
	./install-emacs-command $(TYPETOPOLOGY) $(EMACSDIR)

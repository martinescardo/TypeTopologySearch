-include .install-config.mk

TT ?=
E ?=
TYPETOPOLOGY ?= $(if $(TT),$(TT),$(if $(SAVED_TYPETOPOLOGY),$(SAVED_TYPETOPOLOGY),$(HOME)/TypeTopology))
EMACSDIR ?= $(if $(E),$(E),$(if $(SAVED_EMACSDIR),$(SAVED_EMACSDIR),$(HOME)/.emacs.d))

.PHONY: all search-page definitions agda-input-dump compile install update upgrade clean

all: search-page definitions agda-input-dump compile

search-page:
	./generate-search-page $(TYPETOPOLOGY)

definitions:
	./generate-definitions $(TYPETOPOLOGY)

agda-input-dump:
	./generate-agda-input-dump

compile:
	./compile-emacs-command

install: search-page definitions compile
	./install-emacs-command $(TYPETOPOLOGY) $(EMACSDIR)
	@printf 'SAVED_TYPETOPOLOGY := %s\nSAVED_EMACSDIR := %s\n' \
	    "$(TYPETOPOLOGY)" "$(EMACSDIR)" > .install-config.mk

update:
	git pull
	$(MAKE) install

upgrade: update

clean:
	rm -f TypeTopologySearch.html Definitions.tsv Definitions.txt definitions.json \
	      IdentifierIndex.md ConceptIndex.md Concept-*.md Symbols*.md [A-Z].md \
	      agda-input.el latin-ltx.el agda-input-dump.tsv *.elc
	rm -rf __pycache__

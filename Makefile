PROJECT = $(notdir $(PWD))
TARBALL = $(PROJECT)
REBAR 	= rebar

all:
	@$(REBAR) compile

clean doc:
	@$(REBAR) $@

docs: doc
    
clean-docs:
	rm -f doc/*.{css,html,png} doc/edoc-info

github-docs:
	@if git branch | grep -q gh-pages ; then \
        git checkout gh-pages; \
    else \
        git checkout -b gh-pages; \
    fi
	rm -f rebar.lock
	git checkout master -- src include Makefile rebar.*
	make docs
	ls -1 doc/
	mv doc/*.* .
	make clean
	rm -fr src include Makefile erl_crash.dump priv etc rebar.* README*
	@FILES=`git st -uall --porcelain | sed -n '/^?? [A-Za-z0-9]/{s/?? //p}'`; \
	for f in $$FILES ; do \
	    echo "Adding $$f"; git add $$f; \
	done
	@sh -c "ret=0; set +e; \
	    if   git commit -a --amend -m 'Documentation updated'; \
	    then git push origin +gh-pages; echo 'Pushed gh-pages to origin'; \
	    else ret=1; git reset --hard; \
	    fi; \
	    set -e; git checkout master && echo 'Switched to master'; exit $$ret"

tar:
	rm $(PROJECT).tgz; \
	tar zcf $(TARBALL).tgz --transform 's|^|$(TARBALL)/|' --exclude="core*" --exclude="erl_crash.dump" \
        --exclude="*.tgz" --exclude="*.swp" \
        --exclude="*.o" --exclude=".git" --exclude=".svn" * && \
        echo "Created $(TARBALL).tgz"

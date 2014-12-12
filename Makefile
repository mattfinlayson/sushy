BUNDLE=sushy.zip
HYFILES=$(wildcard sushy/*.hy)
PYFILES=$(wildcard sushy/*.py)
BYTECODE=$(HYFILES:.hy=.pyc)
PYTHONCODE=$(HYFILES:.hy=.py)
export BIND_ADDRESS=0.0.0.0
export HTTP_PORT=8080
export CONTENT_PATH=pages
export STATIC_PATH=static
export PYTHONPATH=$(BUNDLE)
export DATABASE_PATH=index.db


repl:
	hy

deps:
	pip install -r requirements.minimal.txt

clean:
	rm -f *.zip
	rm -f $(BYTECODE)
	rm -f $(PYTHONCODE)
	rm -f $(DATABASE_PATH)

# Turn Hy files into bytecode so that we can use a standard Python interpreter
%.pyc: %.hy
	hyc $<

# Turn Hy files into Python source so that PyPy will be happy
%.py: %.hy
	hy2py $< > $@

build: $(BYTECODE) 

# Experimental bundle to see if we can deploy this solely as a ZIP file
bundle: $(HYFILES) $(PYFILES)
	zip -r9 $(BUNDLE) sushy/* -i *.py *.pyc
	rm -f sushy/*.pyc

# Run with the embedded web server
serve: build
	python -m sushy.app

# Run with uwsgi
uwsgi: build
	uwsgi --ini uwsgi.ini
    
# Run with the embedded web server
index: build
	python -m sushy.indexer

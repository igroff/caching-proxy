SHELL=/bin/bash
.PHONY: watch lint clean install test-server

APP_NAME?=$(shell basename `pwd`)
	
watch: install
	DEBUG=$${DEBUG-true} ./node_modules/.bin/supervisor --watch 'src/,./' --ignore "./test"  -e "litcoffee,coffee,js" --exec make run-server

test-server: install
	DEBUG=$${DEBUG-true} TARGET_CONFIG_PATH=./difftest/etc/target_config.json ./node_modules/.bin/supervisor --watch 'src/,./' --ignore "./test"  -e "litcoffee,coffee,js" --exec make run-server

lint:
	find ./src -name '*.coffee' | xargs ./node_modules/.bin/coffeelint -f ./etc/coffeelint.conf
	find ./src -name '*.js' | xargs ./node_modules/.bin/jshint 

install: node_modules/

node_modules/:
	npm install .

build_output/: node_modules/
	mkdir -p build_output

run-server: build_output/
	exec bash -c "export APP_NAME=${APP_NAME}; test -r ~/.${APP_NAME}.env && . ~/.${APP_NAME}.env ; exec ./node_modules/.bin/coffee server.coffee"

clean:
	rm -rf ./node_modules/

#! /bin/sh

# Download http://dl.google.com/closure-compiler/compiler-latest.zip
# and unzip it in closure/ before running this script.

java -jar closure/compiler.jar \
	--language_in ECMASCRIPT5 \
	--compilation_level SIMPLE \
	--js_output_file=www/js/remoteglot.min.js \
	--externs externs/jquery-1.9.js \
	--externs externs/webstorage.js \
	www/js/chessboard-0.3.0.js \
	www/js/chess.js \
	www/js/json_delta.js \
	www/js/remoteglot.js


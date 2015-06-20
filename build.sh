#! /bin/sh

# Download http://dl.google.com/closure-compiler/compiler-latest.zip
# and unzip it in closure/ before running this script.

# The JQuery build comes from http://projects.jga.me/jquery-builder/,
# more specifically
#
# https://raw.githubusercontent.com/jgallen23/jquery-builder/0.7.0/dist/2.1.1/jquery-deprecated-sizzle.js

java -jar closure/compiler.jar \
	--language_in ECMASCRIPT5 \
	--compilation_level SIMPLE \
	--js_output_file=www/js/remoteglot.min.js \
	--externs externs/webstorage.js \
        www/js/jquery-deprecated-sizzle.js \
	www/js/chessboard-0.3.0.js \
	www/js/chess.js \
	www/js/json_delta.js \
	www/js/jquery.sparkline.js \
	www/js/remoteglot.js


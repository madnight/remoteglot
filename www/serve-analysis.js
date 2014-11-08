// node.js version of analysis.pl; hopefully scales a bit better
// for this specific kind of task.

// Modules.
var http = require('http');
var fs = require('fs');
var url = require('url');
var querystring = require('querystring');
var path = require('path');
var zlib = require('zlib');

// Constants.
var json_filename = '/srv/analysis.sesse.net/www/analysis.json';

// The current contents of the file to hand out, and its last modified time.
var json_contents = undefined;
var json_contents_gz = undefined;
var json_last_modified = undefined;

// The list of clients that are waiting for new data to show up,
// and their associated timers. Uniquely keyed by request_id
// so that we can take them out of the queue if they time out.
var sleeping_clients = {};
var request_id = 0;

// List of when clients were last seen, keyed by their unique ID.
// Used to show a viewer count to the user.
var last_seen_clients = {};

var reread_file = function(event, filename) {
	if (filename != path.basename(json_filename)) {
		return;
	}
	console.log("Rereading " + json_filename);
	fs.open(json_filename, 'r+', function(err, fd) {
		if (err) throw err;
		fs.fstat(fd, function(err, st) {
			if (err) throw err;
			var buffer = new Buffer(1048576);
			fs.read(fd, buffer, 0, 1048576, 0, function(err, bytesRead, buffer) {
				if (err) throw err;
				fs.close(fd, function() {
					var new_json_contents = buffer.toString('utf8', 0, bytesRead);
					zlib.gzip(new_json_contents, function(err, buffer) {
						if (err) throw err;
						json_contents = new_json_contents;
						json_contents_gz = buffer;
						json_last_modified = st.mtime.getTime();
						possibly_wakeup_clients();
					});
				});
			});
		});
	});
}
var possibly_wakeup_clients = function() {
	for (var i in sleeping_clients) {
		clearTimeout(sleeping_clients[i].timer);
		send_json(sleeping_clients[i].response, sleeping_clients[i].accept_gzip);
	}
	sleeping_clients = {};
}
var send_404 = function(response) {
	response.writeHead(404, {
		'Content-Type': 'text/plain',
	});
	response.write('Something went wrong. Sorry.');
	response.end();
}
var send_json = function(response, accept_gzip) {
	var headers = {
		'Content-Type': 'text/json',
		'X-Remoteglot-Last-Modified': json_last_modified,
		'X-Remoteglot-Num-Viewers': count_viewers(),
		'Access-Control-Allow-Origin': 'http://analysis.sesse.net',
		'Access-Control-Expose-Headers': 'X-Remoteglot-Last-Modified, X-Remoteglot-Num-Viewers',
		'Expires': 'Mon, 01 Jan 1970 00:00:00 UTC',
	};

	if (accept_gzip) {
		headers['Content-Encoding'] = 'gzip';
		response.writeHead(200, headers);
		response.write(json_contents_gz);
	} else {
		response.writeHead(200, headers);
		response.write(json_contents);
	}
	response.end();
}
var timeout_client = function(client) {
	send_json(client.response, client.accept_gzip);
	delete sleeping_clients[client.request_id];
}
var count_viewers = function() {
	var now = (new Date).getTime();

	// Go through and remove old viewers, and count them at the same time.
	var new_last_seen_clients = {};
	var num_viewers = 0;
	for (var unique in last_seen_clients) {
		if (now - last_seen_clients[unique] < 60000) {
			++num_viewers;
			new_last_seen_clients[unique] = last_seen_clients[unique];
		}
	}
	last_seen_clients = new_last_seen_clients;
	return num_viewers;
}

// Set up a watcher to catch changes to the file, then do an initial read
// to make sure we have a copy.
fs.watch(path.dirname(json_filename), reread_file);
reread_file(null, path.basename(json_filename));

http.createServer(function(request, response) {
	var u = url.parse(request.url, true);
	var ims = (u.query)['ims'];
	var unique = (u.query)['unique'];

	console.log((new Date).getTime()*1e-3 + " " + request.url);

	if (u.pathname !== '/analysis.pl') {
		// This is not the request you are looking for.
		send_404(response);
		return;
	}

	if (unique) {
		last_seen_clients[unique] = (new Date).getTime();
	}

	var accept_encoding = request.headers['accept-encoding'];
	var accept_gzip;
	if (accept_encoding !== undefined && accept_encoding.match(/\bgzip\b/)) {
		accept_gzip = true;
	} else {
		accept_gzip = false;
	}

	// If we already have something newer than what the user has,
	// just send it out and be done with it.
	if (json_last_modified !== undefined && (!ims || json_last_modified > ims)) {
		send_json(response, accept_gzip);
		return;
	}

	// OK, so we need to hang until we have something newer.
	// Put the user on the wait list; if we don't get anything
	// in 30 seconds, though, we'll send something anyway.
	var client = {};
	client.response = response;
	client.timer = setTimeout(function() { timeout_client(client); }, 30000);
	client.request_id = request_id;
	client.accept_gzip = accept_gzip;
	sleeping_clients[request_id++] = client;
}).listen(5000);

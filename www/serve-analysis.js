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

// The list of clients that are waiting for new data to show up.
// Uniquely keyed by request_id so that we can take them out of
// the queue if they close the socket.
var sleeping_clients = {};
var request_id = 0;

// List of when clients were last seen, keyed by their unique ID.
// Used to show a viewer count to the user.
var last_seen_clients = {};

// The timer used to touch the file every 30 seconds if nobody
// else does it for us. This makes sure we don't have clients
// hanging indefinitely (which might have them return errors).
var touch_timer = undefined;

// If we are behind Varnish, we can't count the number of clients
// ourselves, so some external log-tailing daemon needs to tell us.
var viewer_count_override = undefined;

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

	if (touch_timer !== undefined) {
		clearTimeout(touch_timer);
	}
	touch_timer = setTimeout(function() {
		console.log("Touching analysis.json due to no other activity");
		var now = Date.now() / 1000;
		fs.utimes(json_filename, now, now);
	}, 30000);
}
var possibly_wakeup_clients = function() {
	var num_viewers = count_viewers();
	for (var i in sleeping_clients) {
		mark_recently_seen(sleeping_clients[i].unique);
		send_json(sleeping_clients[i].response,
		          sleeping_clients[i].accept_gzip,
			  num_viewers);
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
var handle_viewer_override = function(request, u, response) {
	// Only accept requests from localhost.
	var peer = request.socket.localAddress;
	if ((peer != '127.0.0.1' && peer != '::1') || request.headers['x-forwarded-for']) {
		console.log("Refusing viewer override from " + peer);
		send_404(response);
	} else {
		viewer_count_override = (u.query)['num'];
		response.writeHead(200, {
			'Content-Type': 'text/plain',
		});
		response.write('OK.');
		response.end();
	}
}
var send_json = function(response, accept_gzip, num_viewers) {
	var headers = {
		'Content-Type': 'text/json',
		'X-Remoteglot-Last-Modified': json_last_modified,
		'X-Remoteglot-Num-Viewers': num_viewers,
		'Access-Control-Allow-Origin': 'http://analysis.sesse.net',
		'Access-Control-Expose-Headers': 'X-Remoteglot-Last-Modified, X-Remoteglot-Num-Viewers',
		'Expires': 'Mon, 01 Jan 1970 00:00:00 UTC',
		'Vary': 'Accept-Encoding',
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
var mark_recently_seen = function(unique) {
	if (unique) {
		last_seen_clients[unique] = (new Date).getTime();
	}
}
var count_viewers = function() {
	if (viewer_count_override !== undefined) {
		return viewer_count_override;
	}

	var now = (new Date).getTime();

	// Go through and remove old viewers, and count them at the same time.
	var new_last_seen_clients = {};
	var num_viewers = 0;
	for (var unique in last_seen_clients) {
		if (now - last_seen_clients[unique] < 5000) {
			++num_viewers;
			new_last_seen_clients[unique] = last_seen_clients[unique];
		}
	}

	// Also add sleeping clients that we would otherwise assume timed out.
	for (var request_id in sleeping_clients) {
		var unique = sleeping_clients[request_id].unique;
		if (unique && !(unique in new_last_seen_clients)) {
			++num_viewers;
		}
	}

	last_seen_clients = new_last_seen_clients;
	return num_viewers;
}

// Set up a watcher to catch changes to the file, then do an initial read
// to make sure we have a copy.
fs.watch(path.dirname(json_filename), reread_file);
reread_file(null, path.basename(json_filename));

var server = http.createServer();
server.on('request', function(request, response) {
	var u = url.parse(request.url, true);
	var ims = (u.query)['ims'];
	var unique = (u.query)['unique'];

	console.log((new Date).getTime()*1e-3 + " " + request.url);
	if (u.pathname === '/override-num-viewers') {
		handle_viewer_override(request, u, response);
		return;
	}
	if (u.pathname !== '/analysis.pl') {
		// This is not the request you are looking for.
		send_404(response);
		return;
	}

	mark_recently_seen(unique);

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
		send_json(response, accept_gzip, count_viewers());
		return;
	}

	// OK, so we need to hang until we have something newer.
	// Put the user on the wait list.
	var client = {};
	client.response = response;
	client.request_id = request_id;
	client.accept_gzip = accept_gzip;
	client.unique = unique;
	sleeping_clients[request_id++] = client;

	request.socket.client = client;
});
server.on('connection', function(socket) {
	socket.on('close', function() {
		var client = socket.client;
		if (client) {
			mark_recently_seen(client.unique);
			delete sleeping_clients[client.request_id];
		}
	});
});
server.listen(5000);
